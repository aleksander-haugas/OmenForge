#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
// Small unprivileged CLI, intended also for QProcess in the Qt6 panel.
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <grp.h>
#include <pwd.h>
#include <algorithm>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

static bool current_has_group(gid_t target) {
    if (getegid()==target) return true;
    const int n=getgroups(0,nullptr);
    if(n<0 || n>256) return false;
    std::vector<gid_t> ids(static_cast<size_t>(n));
    if(n==0) return false;
    if(getgroups(n,ids.data())<0) return false;
    return std::find(ids.begin(),ids.end(),target)!=ids.end();
}
static bool database_has_group(gid_t target) {
    const passwd *p=getpwuid(getuid());
    if(!p || !p->pw_name) return false;
    int n=0;
    getgrouplist(p->pw_name,p->pw_gid,nullptr,&n);
    if(n<1 || n>256) return false;
    std::vector<gid_t> ids(static_cast<size_t>(n));
    if(getgrouplist(p->pw_name,p->pw_gid,ids.data(),&n)<0) return false;
    return std::find(ids.begin(),ids.end(),target)!=ids.end();
}
static void explain_socket_denial(int error) {
    std::cerr<<"No se puede conectar a omen_control_daemon: "<<strerror(error)<<".\n";
    if(error!=EACCES && error!=EPERM) {
        std::cerr<<"Comprueba: sudo service omen_control_daemon status\n";
        return;
    }
    const group *g=getgrnam("omencontrol");
    if(!g) {
        std::cerr<<"Falta el grupo omencontrol; vuelve a ejecutar el instalador como root.\n";
        return;
    }
    if(!database_has_group(g->gr_gid)) {
        std::cerr<<"Tu cuenta no figura en omencontrol. Autorizala UNA VEZ:\n"
                 <<"  sudo pw groupmod omencontrol -m \"$(id -un)\"\n";
    } else if(!current_has_group(g->gr_gid)) {
        std::cerr<<"Tu cuenta pertenece a omencontrol, pero esta sesion aun NO "
                    "tiene ese grupo. Cierra COMPLETAMENTE KDE y vuelve a entrar.\n"
                 <<"Comprueba con: id -Gn\n";
    } else {
        std::cerr<<"Tienes el grupo, pero el socket no permite conectar. Comprueba:\n"
                 <<"  ls -ld /var/run/omen-control\n"
                 <<"  ls -l /var/run/omen-control/control.sock\n"
                 <<"  sudo service omen_control_daemon status\n";
    }
}

#ifndef OMEN_SOCKET_DIR
#define OMEN_SOCKET_DIR "/var/run/omen-control"
#endif
static constexpr const char *SOCKET_PATH=OMEN_SOCKET_DIR "/control.sock";
int main(int argc,char **argv) {
    if(argc<2 || argc>4) {std::cerr<<"Usage: omen-control-client status | power eco|balanced|performance ID | thermal manual|automatic|maximum ID | auto-profile eco|balanced|performance ID | fan-off\n";return 64;}
    std::string request;
    for(int i=1;i<argc;++i){if(i>1)request+=' ';request+=argv[i];}
    request+='\n';
    if(request.size()>128 || request.find_first_of("\r\t")!=std::string::npos) {std::cerr<<"Invalid request\n";return 64;}
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0){perror("socket");return 69;}
    sockaddr_un sa{};sa.sun_family=AF_UNIX;
    if(strlen(SOCKET_PATH)>=sizeof(sa.sun_path)){std::cerr<<"Socket path too long\n";return 69;}
    strcpy(sa.sun_path,SOCKET_PATH);
    if(connect(fd,reinterpret_cast<sockaddr*>(&sa),sizeof(sa))!=0) {
        const int error=errno;
        explain_socket_denial(error);close(fd);return 69;
    }
#if defined(__FreeBSD__)
    uid_t uid=static_cast<uid_t>(-1);gid_t gid=static_cast<gid_t>(-1);
    if(getpeereid(fd,&uid,&gid)!=0 || uid!=0){std::cerr<<"Error: servidor no autentificado como root\n";close(fd);return 77;}
#elif defined(__linux__)
    struct ucred cred{};socklen_t len=sizeof(cred);
    if(getsockopt(fd,SOL_SOCKET,SO_PEERCRED,&cred,&len)!=0 || cred.uid!=0){std::cerr<<"Error: servidor no autentificado como root\n";close(fd);return 77;}
#endif
    size_t off=0;
    while(off<request.size()){auto n=write(fd,request.data()+off,request.size()-off);
        if(n<0 && errno==EINTR)continue;
        if(n<=0){std::cerr<<"Socket write failed\n";close(fd);return 74;}off+=static_cast<size_t>(n);}
    shutdown(fd,SHUT_WR);
    std::string reply;char b[2048];
    while(reply.size()<66000) {
        auto n=read(fd,b,sizeof(b));if(n<0 && errno==EINTR)continue;
        if(n<=0)break;
        reply.append(b,static_cast<size_t>(n));
    }
    close(fd);
    const std::string marker="\n__OMEN_EXIT__:";
    auto at=reply.rfind(marker);
    if(at==std::string::npos){std::cerr<<"Broker did not return a completion code\n";return 74;}
    std::string status=reply.substr(at+marker.size());
    size_t stop=status.find('\n');if(stop!=std::string::npos)status.resize(stop);
    if(status.empty() || status.size()>3) {std::cerr<<"Invalid broker response code\n";return 74;}
    for(char c:status) if(c<'0' || c>'9') {std::cerr<<"Malformed broker response code\n";return 74;}
    const int rc=std::atoi(status.c_str());
    if(at)std::cout<<reply.substr(0,at)<<'\n';
    return rc==0?0:(rc>=1&&rc<=125?rc:70);
}
