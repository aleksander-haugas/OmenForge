#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
// HP OMEN control broker v0.4.4, FreeBSD. Root-only daemon behind a group-restricted UNIX socket.
// The broker does not accept shell text, paths, environment overrides, or raw ACPI/WMI requests.
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>
#include <iostream>
#include <chrono>
#include <sstream>
#include <ctime>

#ifndef OMEN_SOCKET_DIR
#define OMEN_SOCKET_DIR "/var/run/omen-control"
#endif
#ifndef OMEN_BACKEND_PATH
#define OMEN_BACKEND_PATH "/usr/local/libexec/omen-mode-control"
#endif
#ifndef OMEN_CONTROL_PATH
#define OMEN_CONTROL_PATH "/usr/local/libexec/omenctl-control"
#endif
#ifndef OMEN_GROUP_NAME
#define OMEN_GROUP_NAME "omencontrol"
#endif
#ifndef OMEN_LOCK_PATH
#define OMEN_LOCK_PATH "/var/run/omen-control/actions.lock"
#endif
static constexpr const char *SOCKET_PATH = OMEN_SOCKET_DIR "/control.sock";

#ifndef OMEN_STATE_PATH
#define OMEN_STATE_PATH "/var/run/omen-power-thermal.state"
#endif
struct AutoState {
    std::string mode, selected, request_id;
};
static bool read_auto_state(AutoState &out) {
    int fd=open(OMEN_STATE_PATH,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return false;
    struct stat st{};
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_uid!=0 ||
       (st.st_mode & 022)!=0 || st.st_size<0 || st.st_size>4096) {
        close(fd); return false;
    }
    std::string data;
    char buf[512];
    while(data.size()<=4096) {
        ssize_t n=read(fd,buf,sizeof(buf));
        if(n<0 && errno==EINTR) continue;
        if(n<0) { close(fd); return false; }
        if(n==0) break;
        data.append(buf,static_cast<size_t>(n));
    }
    close(fd);
    if(data.size()>4096) return false;
    std::istringstream in(data);
    std::string line;
    while(std::getline(in,line)) {
        auto eq=line.find('=');
        if(eq==std::string::npos) continue;
        const std::string key=line.substr(0,eq), value=line.substr(eq+1);
        if(key=="mode") out.mode=value;
        else if(key=="selected") out.selected=value;
        else if(key=="request_id") out.request_id=value;
    }
    return !out.mode.empty() && !out.request_id.empty();
}
static bool auto_state_matches(const std::string &id) {
    AutoState st;
    return read_auto_state(st) && st.mode=="automatic" && st.request_id==id;
}
static bool commit_auto_state(const std::string &target,const std::string &id) {
    if(!auto_state_matches(id)) return false;
    char stamp[64]{};
    std::time_t now=std::time(nullptr);
    std::tm tmv{};
    if(!localtime_r(&now,&tmv) || std::strftime(stamp,sizeof(stamp),"%Y-%m-%dT%H:%M:%S%z",&tmv)==0) return false;
    char temp[128]{};
    std::snprintf(temp,sizeof(temp),"%s.auto.%ld",OMEN_STATE_PATH,static_cast<long>(getpid()));
    int fd=open(temp,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0644);
    if(fd<0) return false;
    const std::string body="mode=automatic\nselected="+target+"\ntime="+stamp+"\nrequest_id="+id+"\n";
    size_t off=0;
    bool ok=true;
    while(off<body.size()) {
        ssize_t n=write(fd,body.data()+off,body.size()-off);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) {ok=false;break;}
        off+=static_cast<size_t>(n);
    }
    if(ok && fsync(fd)!=0) ok=false;
    if(fchmod(fd,0644)!=0) ok=false;
    if(close(fd)!=0) ok=false;
    // Legitimate state writers are serialized by actions.lock.
    if(ok && auto_state_matches(id) && rename(temp,OMEN_STATE_PATH)==0) return true;
    unlink(temp);
    return false;
}
static volatile sig_atomic_t stopping = 0;
static void onterm(int) { stopping = 1; }
static void logerr(const std::string &s) { std::cerr << "omen-control-daemon: " << s << '\n'; }
static bool safe_owned_file(const char *p) {
    struct stat st{};
    if (lstat(p,&st)!=0 || !S_ISREG(st.st_mode) || st.st_uid!=0 || (st.st_mode & 022)!=0 || (st.st_mode & S_IXUSR)==0) return false;
    return true;
}
static bool safe_base_directory(const char *path) {
    struct stat st{};
    return stat(path,&st)==0 && S_ISDIR(st.st_mode) && st.st_uid==0 && (st.st_mode & 0022)==0;
}
static bool safe_directory(const char *path) {
    struct stat st{};
    return lstat(path,&st)==0 && S_ISDIR(st.st_mode) && st.st_uid==0 && (st.st_mode & 0022)==0;
}
static bool sendall(int fd, const std::string &s) {
    const char *p=s.data(); size_t n=s.size();
    while(n) { auto written=write(fd,p,n); if(written<0 && errno==EINTR) continue;
        if(written<=0) return false;
        p+=written; n-=static_cast<size_t>(written); }
    return true;
}
static bool one_line(int fd, std::string &line) {
    pollfd pfd{fd,POLLIN,0};
    if(poll(&pfd,1,5000)<=0) return false;
    char ch=0;
    while(line.size()<128) {
        auto rc=read(fd,&ch,1);
        if(rc<0 && errno==EINTR) continue;
        if(rc<=0) return false;
        if(ch=='\n') return true;
        if(ch<32 || ch>126) return false;
        line+=ch;
    }
    return false;
}
static bool has_access(uid_t u, gid_t authorized) {
    if(u==0) return true;
    // Check peer UID against current OS group membership, not arbitrary client text.
    struct passwd *pw=getpwuid(u);
    if(!pw || !pw->pw_name) return false;
    int n=0;
    getgrouplist(pw->pw_name,pw->pw_gid,nullptr,&n);
    if(n<1 || n>256) return false;
    std::vector<gid_t> groups(static_cast<size_t>(n));
    if(getgrouplist(pw->pw_name,pw->pw_gid,groups.data(),&n)<0) return false;
    return std::find(groups.begin(),groups.end(),authorized)!=groups.end();
}
static bool valid_id(const std::string &v) {
    if(v.size()<12 || v.size()>20) return false;
    return std::all_of(v.begin(),v.end(),[](char c){return c>='0'&&c<='9';});
}
static std::vector<std::string> split(const std::string &v) {
    std::vector<std::string> out;
    size_t from=0;
    for(;;) {auto p=v.find(' ',from); if(p==std::string::npos) {out.push_back(v.substr(from)); break;}
        out.push_back(v.substr(from,p-from)); from=p+1; }
    return out;
}
static bool valid_command(const std::vector<std::string> &a) {
    if(a.size()==1) return a[0]=="status" || a[0]=="fan-off";
    if(a.size()!=3 || !valid_id(a[2])) return false;
    if(a[0]=="power") return a[1]=="eco" || a[1]=="balanced" || a[1]=="performance";
    if(a[0]=="thermal") return a[1]=="manual" || a[1]=="automatic" || a[1]=="maximum";
    if(a[0]=="auto-profile") return a[1]=="eco" || a[1]=="balanced" || a[1]=="performance";
    return false;
}
static void handle_client(int peer, gid_t allowed_group) {
    uid_t uid=static_cast<uid_t>(-1);gid_t gid=static_cast<gid_t>(-1);
#if defined(__FreeBSD__)
    if(getpeereid(peer,&uid,&gid)!=0) {sendall(peer,"ERROR: peer credentials unavailable\n__OMEN_EXIT__:77\n");return;}
#elif defined(__linux__)
    struct ucred cred{};socklen_t len=sizeof(cred);
    if(getsockopt(peer,SOL_SOCKET,SO_PEERCRED,&cred,&len)!=0) {sendall(peer,"ERROR: credentials unavailable\n__OMEN_EXIT__:77\n");return;}
    uid=cred.uid;gid=cred.gid;
#else
#error "Unsupported OS: requires peer credentials"
#endif
    (void)gid; // peer GID obtained as part of authenticated credentials; group membership checked against the current OS group DB
    if(!has_access(uid,allowed_group)) {sendall(peer,"ERROR: user not authorized for omencontrol\n__OMEN_EXIT__:77\n");return;}
    std::string line;
    if(!one_line(peer,line)) {sendall(peer,"ERROR: malformed or timed-out request\n__OMEN_EXIT__:64\n");return;}
    const auto args=split(line);
    if(!valid_command(args)) {sendall(peer,"ERROR: operation not permitted\n__OMEN_EXIT__:64\n");return;}
    const bool emergency=(args.size()==1 && args[0]=="fan-off");
    const bool readonly=(args.size()==1 && args[0]=="status");
    const bool automatic_profile=(args.size()==3 && args[0]=="auto-profile");
    int lockfd=-1;
    if(!readonly && !emergency) {
        lockfd=open(OMEN_LOCK_PATH,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if(lockfd<0 || flock(lockfd,LOCK_EX|LOCK_NB)!=0) {
            sendall(peer,"ERROR: another HP control operation is active\n__OMEN_EXIT__:75\n");
            if(lockfd>=0) close(lockfd);
            return;
        }
    }
    if(automatic_profile && !auto_state_matches(args[2])) {
        sendall(peer,"ERROR: automatic profile request is stale or mode is not automatic\n__OMEN_EXIT__:75\n");
        if(lockfd>=0) close(lockfd);
        return;
    }
    const char *bin= (emergency || automatic_profile)?OMEN_CONTROL_PATH:OMEN_BACKEND_PATH;
    if(!safe_owned_file(bin)) {
        sendall(peer,"ERROR: backend missing or unsafe ownership/permissions\n__OMEN_EXIT__:77\n");
        if(lockfd>=0) close(lockfd);
            return;
    }
    int pipes[2];
    if(pipe(pipes)<0) {sendall(peer,"ERROR: pipe failed\n__OMEN_EXIT__:74\n");if(lockfd>=0)close(lockfd);return;}
    const pid_t pid=fork();
    if(pid<0) {close(pipes[0]);close(pipes[1]);sendall(peer,"ERROR: fork failed\n__OMEN_EXIT__:74\n");if(lockfd>=0)close(lockfd);return;}
    if(pid==0) {
        signal(SIGCHLD,SIG_DFL);
        close(pipes[0]);
        dup2(pipes[1],STDOUT_FILENO); dup2(pipes[1],STDERR_FILENO);
        close(pipes[1]);
        close(peer);
        if(lockfd>=0)close(lockfd);
        const char *argv[6]={};
        if(emergency) {argv[0]=bin;argv[1]="fan-max";argv[2]="off";argv[3]="--apply";}
        else if(automatic_profile) {
            argv[0]=bin; argv[1]="profile";
            argv[2]=(args[1]=="eco" ? "cool" : args[1].c_str());
            argv[3]="--apply";
        } else {
            argv[0]=bin;
            for(size_t i=0;i<args.size();++i) argv[i+1]=args[i].c_str();
        }
        clearenv();
        setenv("PATH","/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin",1);
        setenv("HOME","/root",1);
        setenv("LC_ALL","C",1);
        execv(bin,const_cast<char *const *>(argv));
        _exit(127);
    }
    close(pipes[1]);
    // El controlador puede arrancar un servicio FreeBSD en background.
    // Sus descendientes pueden heredar stdout/stderr (pipe write end).
    // Leer hasta EOF bloquearia la respuesta aunque el script ORIGINAL
    // haya acabado. Terminar basandose en waitpid() del hijo directo.
    const int flags=fcntl(pipes[0],F_GETFL,0);
    if(flags>=0) fcntl(pipes[0],F_SETFL,flags|O_NONBLOCK);
    using Clock=std::chrono::steady_clock;
    const auto begin=Clock::now();
    auto exitedAt=begin;
    const int actionLimit=(args.size()==3 && args[0]=="thermal" && args[1]=="maximum")?35:35;
    bool exited=false, eof=false, timedOut=false, waitFailed=false;
    int childStatus=0;
    size_t count=0;
    char buf[2048];
    auto reap=[&]() {
        if(exited) return;
        pid_t r=waitpid(pid,&childStatus,WNOHANG);
        if(r==pid){exited=true;exitedAt=Clock::now();}
        else if(r<0 && errno!=EINTR){exited=true;waitFailed=true;exitedAt=Clock::now();}
    };
    while(true) {
        reap();
        const auto now=Clock::now();
        if(!exited && now-begin > std::chrono::seconds(actionLimit)) {
            // Matar SOLO al script hijo que agoto el plazo. Una operacion
            // WMI podria haber empezado: informar resultado NO confirmado.
            kill(pid,SIGTERM);
            timedOut=true;
            break;
        }
        if(exited && (eof || now-exitedAt > std::chrono::milliseconds(650))) break;
        if(eof){ usleep(50000); continue; } // Esperar al comando, no girar sobre POLLHUP.
        pollfd pfd{pipes[0],static_cast<short>(POLLIN|POLLHUP),0};
        int pr=poll(&pfd,1,200);
        if(pr<0 && errno==EINTR) continue;
        if(pr<0) break;
        if(pr==0) continue;
        while(true) {
            const ssize_t n=read(pipes[0],buf,sizeof(buf));
            if(n>0){
                if(count<65536){
                    size_t accepted=std::min(static_cast<size_t>(n),static_cast<size_t>(65536-count));
                    sendall(peer,std::string(buf,accepted));count+=accepted;
                }
                continue;
            }
            if(n==0) eof=true;
            if(n<0 && errno==EINTR) continue;
            break;  // EOF o EAGAIN: nunca bloquear esperando un nieto.
        }
    }
    close(pipes[0]);
    if(!exited){
        // Limitar tambien el reaping; no bloquear indefinidamente.
        auto until=Clock::now()+std::chrono::seconds(2);
        do {
            auto r=waitpid(pid,&childStatus,WNOHANG);
            if(r==pid){exited=true;break;}
            if(r<0 && errno!=EINTR){waitFailed=true;break;}
            usleep(50000);
        } while(Clock::now()<until);
        if(!exited && timedOut) kill(pid,SIGKILL);
    }
    int rc=timedOut?124 : (waitFailed || !exited)?74 :
        (WIFEXITED(childStatus)?WEXITSTATUS(childStatus):128);
    if(timedOut)sendall(peer,"ERROR: tiempo maximo del comando excedido; estado del firmware NO confirmado\n");
    if(automatic_profile && rc==0) {
        if(!auto_state_matches(args[2])) {
            sendall(peer,"ERROR: automatic mode/request changed after firmware operation; state not committed\n");
            rc=75;
        } else if(!commit_auto_state(args[1],args[2])) {
            sendall(peer,"ERROR: firmware profile applied but automatic state commit failed; inspect status\n");
            rc=74;
        } else {
            sendall(peer,"Automatic profile confirmed and state committed: "+args[1]+"\n");
        }
    }
    sendall(peer,"\n__OMEN_EXIT__:"+std::to_string(rc)+"\n");
    if(lockfd>=0)close(lockfd);
}
int main(int argc,char**) {
    if(argc!=1 || geteuid()!=0) {logerr("Must run as root, without arguments, via rc.d");return 77;}
    if(!safe_base_directory("/var/run") || !safe_owned_file(OMEN_BACKEND_PATH) || !safe_owned_file(OMEN_CONTROL_PATH)) {
        logerr("Unsafe runtime directory or root backend permissions");return 77;
    }
    struct group *gp=getgrnam(OMEN_GROUP_NAME);
    if(!gp) {logerr("Group omencontrol not found");return 77;}
    const gid_t grp=gp->gr_gid;
    if(mkdir(OMEN_SOCKET_DIR,0750)<0 && errno!=EEXIST) {perror("mkdir");return 1;}
    if(!safe_directory(OMEN_SOCKET_DIR) || chown(OMEN_SOCKET_DIR,0,grp)!=0 || chmod(OMEN_SOCKET_DIR,0750)!=0) {logerr("Unsafe socket directory");return 1;}
    int sock=socket(AF_UNIX,SOCK_STREAM,0);
    if(sock<0){perror("socket");return 1;}
    struct sockaddr_un sa{};sa.sun_family=AF_UNIX;
    if(strlen(SOCKET_PATH)>=sizeof(sa.sun_path)){logerr("Socket path too long");return 1;}
    strcpy(sa.sun_path,SOCKET_PATH);
    struct stat st{};
    if(lstat(SOCKET_PATH,&st)==0) {
        if(!S_ISSOCK(st.st_mode) || st.st_uid!=0) {logerr("Unexpected object at socket path");return 1;}
        if(unlink(SOCKET_PATH)!=0){perror("unlink");return 1;}
    }else if(errno!=ENOENT){perror("lstat");return 1;}
    mode_t old=umask(0077);
    int ok=bind(sock,reinterpret_cast<sockaddr*>(&sa),sizeof(sa));
    umask(old);
    if(ok!=0){perror("bind");return 1;}
    if(chown(SOCKET_PATH,0,grp)!=0 || chmod(SOCKET_PATH,0660)!=0 || listen(sock,16)!=0) {perror("socket setup");unlink(SOCKET_PATH);return 1;}
    signal(SIGPIPE,SIG_IGN);
    signal(SIGCHLD,SIG_IGN); // children request handlers auto-reaped; each restores SIGCHLD for its subprocess
    signal(SIGTERM,onterm); signal(SIGINT,onterm);
    std::cout<<"omen-control-daemon ready, root-owned socket, group omencontrol\n";
    while(!stopping) {
        pollfd pfd{sock,POLLIN,0};
        int pr=poll(&pfd,1,1000);
        if(pr<=0)continue;
        int client=accept(sock,nullptr,nullptr);
        if(client<0){if(errno==EINTR)continue;perror("accept");continue;}
        pid_t pid=fork();
        if(pid==0){close(sock);signal(SIGCHLD,SIG_DFL);handle_client(client,grp);close(client);_exit(0);}
        close(client);
        if(pid<0)logerr("Cannot fork request worker");
    }
    close(sock); unlink(SOCKET_PATH);return 0;
}
