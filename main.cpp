// HP OMEN Power Mode + Thermal Control v0.4.16 / FreeBSD 15.1 / Plasma 6.
// Qt stays unprivileged; control calls a credential-checked root broker over a local UNIX socket.
// A separate root collector publishes /var/run/omenctl/status atomically.
#include <QtWidgets/QApplication>
#include <QtWidgets/QMainWindow>
#include <QtWidgets/QWidget>
#include <QtWidgets/QLabel>
#include <QtWidgets/QFrame>
#include <QtWidgets/QScrollArea>
#include <QtWidgets/QGridLayout>
#include <QtWidgets/QVBoxLayout>
#include <QtWidgets/QHBoxLayout>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QComboBox>
#include <QtWidgets/QStatusBar>
#include <QtWidgets/QFileDialog>
#include <QtWidgets/QMessageBox>
#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QRegularExpression>
#include <QtCore/QTextStream>
#include <QtCore/QTimer>
#include <QtCore/QProcess>
#include <QtCore/QStringList>
#include <QtCore/QVector>
#include <QtGui/QPainter>
#include <QtGui/QIcon>
#include <QtGui/QFont>
#include <QtGui/QPen>
#include <QtGui/QResizeEvent>
#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

static constexpr double na = std::numeric_limits<double>::quiet_NaN();
struct Sample {
    QDateTime when;
    QString profile;
    int fan0 = -1, fan1 = -1;
    double cpu = na, acpi = na, gpu = na, power = na;
    int gpuLoad = -1, hpcm = -1, gput = -1, sw2s = -1, fffs = -1;
    QString fanStatus = "OK", gpuStatus = "SIN_DATOS";
};

static QString capture(const QString &source, const QString &expression) {
    QRegularExpressionMatch m = QRegularExpression(expression).match(source);
    return m.hasMatch() ? m.captured(1) : QString();
}
static int asInt(const QString &s) { bool ok=false; int n=s.toInt(&ok); return ok?n:-1; }
static double asReal(const QString &s) { bool ok=false; double n=s.toDouble(&ok); return ok?n:na; }
static QString displayTemp(double d) { return std::isfinite(d) ? QString::number(d,'f',1)+" °C" : "N/D"; }
static QString displayRpm(int n) { return n>=0 ? QString::number(n)+" RPM" : "N/D"; }
static QString displayInt(int n) { return n>=0 ? QString::number(n) : "N/D"; }

// Parse only the stable, read-only omenctl v0.3.2 text layout.
static bool parseOmenStatus(const QString &txt, Sample &s) {
    s.profile = capture(txt, "Perfil termico:\\s*([^\\n(]+)\\s*\\(HPCM=");
    s.profile = s.profile.trimmed();
    s.hpcm = asInt(capture(txt,"HPCM=(\\d+)"));
    s.fan0 = asInt(capture(txt,"Fan 0:\\s*(\\d+)\\s*RPM"));
    s.fan1 = asInt(capture(txt,"Fan 1:\\s*(\\d+)\\s*RPM"));
    s.cpu = asReal(capture(txt,"CPU:\\s*([0-9.]+)\\s*C"));
    s.acpi = asReal(capture(txt,"ACPI:\\s*([0-9.]+)\\s*C"));
    s.gpu = asReal(capture(txt,"NVIDIA:\\s*([0-9.]+)\\s*C"));
    s.gpuLoad = asInt(capture(txt,"NVIDIA:\\s*(\\d+)\\s*%\\s*utilizacion"));
    s.power = asReal(capture(txt,"\\|\\s*([0-9.]+)\\s*W"));
    s.gpuStatus = capture(txt,"Estado NVIDIA:\\s*([A-Z_]+)");
    if (s.gpuStatus.isEmpty()) s.gpuStatus=std::isfinite(s.gpu)?"OK":"SIN_DATOS";
    s.gput = asInt(capture(txt,"GPUT:\\s*(\\d+)"));
    s.sw2s = asInt(capture(txt,"SW2S:\\s*(\\d+)"));
    s.fffs = asInt(capture(txt,"FFFS:\\s*(\\d+)"));
    QString note = capture(txt,"Estado tacometros:\\s*([A-Za-z_]+)");
    if (!note.isEmpty()) s.fanStatus=note;
    return !s.profile.isEmpty() && s.hpcm>=0 && s.fan0>=0 && s.fan1>=0;
}


// Importador del CSV propio de omen-panel: columnas simples, sin campos
// entrecomillados ni comas dentro de valores; el formato es intencionalmente fijo.
static bool parseCsvSample(const QString &line, Sample &s) {
    const QStringList f=line.trimmed().split(',', Qt::KeepEmptyParts);
    if (f.size()!=10) return false;
    s.when=QDateTime::fromString(f[0].trimmed(),Qt::ISODate);
    if (!s.when.isValid()) return false;
    s.profile=f[1].trimmed();
    if (s.profile.isEmpty()) return false;
    s.fan0=asInt(f[2].trimmed());
    s.fan1=asInt(f[3].trimmed());
    if (s.fan0<0 || s.fan1<0) return false;
    s.cpu=asReal(f[4].trimmed());
    s.acpi=asReal(f[5].trimmed());
    s.gpu=asReal(f[6].trimmed());
    s.gpuLoad=asInt(f[7].trimmed());
    s.power=asReal(f[8].trimmed());
    s.fanStatus=f[9].trimmed();
    if(s.fanStatus.isEmpty()) s.fanStatus="SIN_DATOS";
    s.gpuStatus=std::isfinite(s.gpu)?"OK":"SIN_DATOS";
    if(s.profile=="Eco") s.hpcm=80;
    else if(s.profile=="Balanced") s.hpcm=48;
    else if(s.profile=="Performance") s.hpcm=49;
    else if(s.profile=="Cool") s.hpcm=80;
    return true;
}

class TrendGraph final : public QWidget {
public:
    enum Category { Temperatures, Fans, GpuPower };
    explicit TrendGraph(Category kind, QWidget *parent = nullptr) : QWidget(parent), kind_(kind) {
        setMinimumHeight(186);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    }
    void setHistory(const QVector<Sample> &v) { history_=v; update(); }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing,true);
        p.fillRect(rect(),QColor("#151d2d"));
        const int h=height(), w=width();
        const QRectF plot(55,36,std::max(10,w-75),std::max(10,h-65));
        p.setFont(QFont("Sans Serif",9));
        const bool fan = kind_==Fans;
        const bool watts = kind_==GpuPower;
        const QStringList labels = watts ? QStringList{"Consumo NVIDIA (W)"} :
            (fan ? QStringList{"Fan 0", "Fan 1"} : QStringList{"CPU", "ACPI", "NVIDIA"});
        const QVector<QColor> colors = watts ? QVector<QColor>{QColor("#73e0bc")} :
            (fan ? QVector<QColor>{QColor("#56d0ff"),QColor("#bc95ff")} :
                   QVector<QColor>{QColor("#56d0ff"),QColor("#ffb86e"),QColor("#bc95ff")});
        int labelX=14;
        for (int j=0;j<labels.size();++j) {
            p.setPen(colors[j]); p.drawText(labelX,19,QString("● %1").arg(labels[j]));
            labelX+=labels[j].size()*9+44;
        }
        if (history_.isEmpty()) {
            p.setPen(QColor("#8793a8"));
            p.drawText(plot,Qt::AlignCenter,"Esperando muestras del colector...");
            return;
        }
        const auto value=[&](const Sample &s,int i)->double {
            if (watts) return s.power;
            if (fan) { const int rpm=i==0?s.fan0:s.fan1; return rpm>0?rpm:na; }
            return i==0?s.cpu:(i==1?s.acpi:s.gpu);
        };
        double low=1e12,high=-1e12;
        for (const auto &s:history_) for (int j=0;j<labels.size();++j) {
            const double v=value(s,j);
            if (std::isfinite(v) && v>=0) {low=std::min(low,v); high=std::max(high,v);}
        }
        if (low>high) {
            p.setPen(QColor("#8793a8"));
            p.drawText(plot,Qt::AlignCenter,"Datos no disponibles: comprueba nvidia-smi en el servicio");
            return;
        }
        const double margin=std::max(fan?50.0:(watts?0.8:2.5),(high-low)*0.18);
        low=std::max(0.0,low-margin); high+=margin;
        if (high-low<1) high=low+1;
        for (int i=0;i<=4;++i) {
            const qreal y=plot.top()+plot.height()*i/4.0;
            p.setPen(QPen(QColor("#293448"),1)); p.drawLine(QPointF(plot.left(),y),QPointF(plot.right(),y));
            p.setPen(QColor("#8897b0"));
            const double v=high-(high-low)*i/4.0;
            p.drawText(QRectF(0,y-10,49,20),Qt::AlignRight|Qt::AlignVCenter,QString::number(v,'f',fan?0:1));
        }
        const int n=history_.size();
        const qint64 fromMs=history_.first().when.toMSecsSinceEpoch();
        const qint64 toMs=history_.last().when.toMSecsSinceEpoch();
        const qint64 duration=std::max<qint64>(1,toMs-fromMs);
        for (int j=0;j<labels.size();++j) {
            p.setPen(QPen(colors[j],2.1,Qt::SolidLine,Qt::RoundCap,Qt::RoundJoin));
            QPolygonF poly;
            const auto flush=[&](){ if(poly.size()>1) p.drawPolyline(poly); else if(poly.size()==1) p.drawEllipse(poly.first(),2,2); poly.clear();};
            for(int i=0;i<n;++i) {
                const double v=value(history_[i],j);
                if (!std::isfinite(v) || v<0) { flush(); continue; }
                const double x=plot.left()+(n==1?plot.width()/2.0:
                     plot.width()*(history_[i].when.toMSecsSinceEpoch()-fromMs)/duration);
                const double y=plot.bottom()-(v-low)*plot.height()/(high-low);
                poly << QPointF(x,y);
            }
            flush();
        }
        p.setPen(QColor("#8897b0"));
        const QString timeline = n>1
            ? history_.first().when.toString("HH:mm:ss")+"   —   "+history_.last().when.toString("HH:mm:ss")
            : history_.first().when.toString("HH:mm:ss");
        p.drawText(QRectF(plot.left(),h-24,plot.width(),19),Qt::AlignCenter,
                   QString("%1  ·  %2 muestras").arg(timeline).arg(n));
    }
private:
    Category kind_;
    QVector<Sample> history_;
};

struct Metric { QFrame *frame=nullptr; QLabel *value=nullptr; QLabel *subtitle=nullptr; };
static Metric card(const QString &title,QGridLayout *grid,int r,int c) {
    auto *frame=new QFrame;
    frame->setObjectName("metric");
    auto *layout=new QVBoxLayout(frame);
    layout->setContentsMargins(20,17,20,16); layout->setSpacing(8);
    auto *label=new QLabel(title.toUpper()); label->setObjectName("metricTitle");
    auto *value=new QLabel("—"); value->setObjectName("metricValue");
    auto *subtitle=new QLabel("Esperando datos"); subtitle->setObjectName("metricSubtitle");
    layout->addWidget(label);layout->addWidget(value);layout->addWidget(subtitle);
    grid->addWidget(frame,r,c);
    return {frame,value,subtitle};
}

class Dashboard final : public QMainWindow {
public:
    explicit Dashboard(const QString &source) : source_(source) {
        setWindowTitle("HP OMEN · Power Mode & Thermal Control · v0.4.16 · FreeBSD");
        setWindowIcon(QIcon(":/icons/omen-icon-256.png"));
        resize(1110,920);setMinimumSize(560,540);
        auto *scroller=new QScrollArea;
        scroller->setFrameShape(QFrame::NoFrame);
        scroller->setWidgetResizable(true);
        setCentralWidget(scroller);
        auto *body=new QWidget;
        auto *vertical=new QVBoxLayout(body);
        vertical->setContentsMargins(25,24,25,22);vertical->setSpacing(18);

        auto *header=new QHBoxLayout;
        auto *headings=new QVBoxLayout;
        auto *brandIcon=new QLabel;
        brandIcon->setPixmap(QIcon(":/icons/omen-icon-128.png").pixmap(54,54));
        brandIcon->setFixedSize(58,58);
        header->addWidget(brandIcon,0,Qt::AlignVCenter);
        auto *title=new QLabel("HP OMEN");title->setObjectName("heading");
        auto *subtitle=new QLabel("POWER MODE  /  THERMAL CONTROL  /  FREEBSD 15.1");
        subtitle->setObjectName("subheading");
        headings->addWidget(title);headings->addWidget(subtitle);
        header->addLayout(headings);header->addStretch();
        auto *mode=new QLabel("CONTROL HP WMI");mode->setObjectName("modeBadge");
        header->addWidget(mode,0,Qt::AlignTop);
        vertical->addLayout(header);

        state_=new QLabel("Conectando al colector...");state_->setObjectName("statusLabel");
        state_->setWordWrap(true);vertical->addWidget(state_);
        // Separacion estricta de energia y refrigeracion; sin nuevas escrituras ACPI.
        auto *powerPanel=new QFrame; powerPanel->setObjectName("controlPanel");
        auto *powerColumn=new QVBoxLayout(powerPanel);
        powerColumn->setSpacing(10);
        auto *powerHeading=new QLabel("POWER MODE");powerHeading->setObjectName("controlHeading");
        powerColumn->addWidget(powerHeading);
        auto *powerRow=new QHBoxLayout;powerRow->setSpacing(9);
        auto addPower=[this,powerRow](const QString &label,const QString &code)->QPushButton* {
            auto *button=new QPushButton(label);
            button->setIcon(QIcon(QString(":/icons/power-%1.png").arg(code)));
            button->setIconSize(QSize(24,24));
            button->setObjectName("powerButton");button->setCheckable(true);
            button->setEnabled(false);
            connect(button,&QPushButton::clicked,this,[this,code]{requestControl("power",code);});
            powerRow->addWidget(button);controlButtons_.append(button);
            return button;
        };
        powerEco_=addPower("Eco","eco");
        powerBalanced_=addPower("Balanced","balanced");
        powerPerformance_=addPower("Performance","performance");
        powerColumn->addLayout(powerRow);
        powerHint_=new QLabel("Eco usa HP Cool (0x50), aún NO equivale al ahorro oficial Eco. El firmware controla el fan-stop.");
        powerHint_->setWordWrap(true);powerHint_->setObjectName("footnote");
        powerColumn->addWidget(powerHint_);
        vertical->addWidget(powerPanel);

        auto *thermalPanel=new QFrame;thermalPanel->setObjectName("controlPanel");
        auto *thermalColumn=new QVBoxLayout(thermalPanel);thermalColumn->setSpacing(10);
        auto *thermalHeading=new QLabel("THERMAL CONTROL");thermalHeading->setObjectName("controlHeading");
        thermalColumn->addWidget(thermalHeading);
        auto *thermalRow=new QHBoxLayout;thermalRow->setSpacing(9);
        auto addThermal=[this,thermalRow](const QString &label,const QString &action)->QPushButton* {
            auto *button=new QPushButton(label);button->setObjectName("thermalButton");button->setEnabled(false);button->setCheckable(true);
            connect(button,&QPushButton::clicked,this,[this,action]{requestControl("thermal",action);});
            thermalRow->addWidget(button);controlButtons_.append(button);
            return button;
        };
        emergencyOffButton_=addThermal("Automatic · inteligente","automatic");
        thermalMaximum_=addThermal("Maximum · FAN MAX sin limite","maximum");
        manualButton_=addThermal("Manual · mantener perfil","manual");
        thermalColumn->addLayout(thermalRow);
        thermalStatus_=new QLabel("Automatic: perfiles segun carga y temperatura | Manual: perfil fijo | Maximum: FAN MAX hasta cambio manual");
        thermalStatus_->setWordWrap(true);thermalStatus_->setObjectName("footnote");
        thermalColumn->addWidget(thermalStatus_);
        vertical->addWidget(thermalPanel);
        auto *controlHint=new QLabel("Eco utiliza HP Cool (ahorro parcial); Automatic adapta el perfil cada 10s con histéresis. "
            "Performance no asegura ventiladores siempre activos; Maximum mantiene FAN MAX hasta que selecciones otro modo. El firmware HP conserva sus protecciones. Las órdenes se envían al servicio privilegiado local.");
        controlHint->setObjectName("footnote");controlHint->setWordWrap(true);
        vertical->addWidget(controlHint);
        auto *historyTools=new QHBoxLayout;
        viewMode_=new QLabel("DIRECTO · " + source_);
        viewMode_->setObjectName("viewMode");
        viewMode_->setWordWrap(true);
        historyTools->addWidget(viewMode_,1);
        auto *openHistory=new QPushButton("Abrir CSV histórico");
        openHistory->setToolTip("Analizar una exportación CSV sin acceder al firmware");
        connect(openHistory,&QPushButton::clicked,this,[this]{
            const QString path=QFileDialog::getOpenFileName(this,"Abrir historial térmico",QString(),"CSV (*.csv)");
            if(!path.isEmpty()) loadCsvPath(path);
        });
        historyTools->addWidget(openHistory);
        backLive_=new QPushButton("Volver a directo");
        backLive_->setEnabled(false);
        connect(backLive_,&QPushButton::clicked,this,[this]{returnToLive();});
        historyTools->addWidget(backLive_);
        vertical->addLayout(historyTools);
        metrics_=new QGridLayout; metrics_->setSpacing(12);
        fan0_=card("Ventilador 0",metrics_,0,0);
        fan1_=card("Ventilador 1",metrics_,0,1);
        prof_=card("Power Mode",metrics_,0,2);
        cpu_=card("Temperatura CPU",metrics_,1,0);
        acpi_=card("Zona termica ACPI",metrics_,1,1);
        gpu_=card("NVIDIA RTX 3070",metrics_,1,2);
        metricWidgets_={fan0_.frame,fan1_.frame,prof_.frame,cpu_.frame,acpi_.frame,gpu_.frame};
        metrics_->setColumnStretch(0,1);
        metrics_->setColumnStretch(1,1);
        metrics_->setColumnStretch(2,1);
        metricColumns_=3;
        vertical->addLayout(metrics_);

        auto *summary=new QLabel("Esperando telemetria...");
        summary->setObjectName("summary");summary->setWordWrap(true);
        summary_=summary;vertical->addWidget(summary);

        auto *graphRow=new QGridLayout;graphRow->setSpacing(12);
        tempGraph_=new TrendGraph(TrendGraph::Temperatures);
        fanGraph_=new TrendGraph(TrendGraph::Fans);
        powerGraph_=new TrendGraph(TrendGraph::GpuPower);
        graphRow->addWidget(graphCard("01   /   TEMPERATURAS",tempGraph_),0,0);
        graphRow->addWidget(graphCard("02   /   VENTILADORES",fanGraph_),1,0);
        graphRow->addWidget(graphCard("03   /   CONSUMO NVIDIA",powerGraph_),2,0);
        vertical->addLayout(graphRow);

        auto *actions=new QHBoxLayout;
        auto *footer=new QLabel("TELEMETRÍA SIN ROOT · DAEMON LOCAL GRUPO OMENCONTROL   /   " + source_ + "   /   Historial local (hasta 2400 muestras), sin registros automaticos");
        footer->setObjectName("footnote");footer->setWordWrap(true);
        actions->addWidget(footer,1);
        auto *exportBtn=new QPushButton("Exportar historial CSV");
        exportBtn->setToolTip("Guarda solamente las muestras acumuladas mientras esta ventana este abierta");
        connect(exportBtn,&QPushButton::clicked,this,[this]{exportHistory();});
        actions->addWidget(exportBtn);
        vertical->addLayout(actions);
        vertical->addStretch(1);
        scroller->setWidget(body);
        setStyleSheet(R"(
            QMainWindow, QScrollArea, QWidget {background:#0b1220;color:#e8f0fc;font-family:'Noto Sans',sans-serif;}
            QLabel#heading {font-size:34px;font-weight:800;letter-spacing:1px;}
            QLabel#subheading, QLabel#footnote {font-size:11px;color:#8596b0;}
            QLabel#modeBadge {background:#12362f;color:#90f2cf;border:1px solid #26745e;
                             border-radius:10px;padding:9px 13px;font-weight:700;font-size:11px;}
            QLabel#statusLabel {background:#16253b;border:1px solid #304963;
                                border-radius:9px;padding:12px;color:#d4e5f9;}
            QFrame#metric {background:#162338;border:1px solid #293c55;border-radius:14px;}
            QFrame#controlPanel {background:#141f32;border:1px solid #30425b;border-radius:12px;padding:7px;}
            QLabel#controlHeading {background:transparent;color:#e7eefc;font-size:14px;font-weight:800;}
            QPushButton#powerButton:checked {background:#7750a7;border:1px solid #d49dff;color:#ffffff;}
            QPushButton#thermalButton:checked {background:#214f58;border:1px solid #58d5d3;color:#ffffff;}
            QComboBox {background:#192c45;color:#e9f0fc;border:1px solid #476a93;border-radius:7px;padding:8px;}
            QLabel#metricTitle {background:transparent;font-weight:700;font-size:11px;color:#95aac6;}
            QLabel#metricValue {background:transparent;font-weight:750;font-size:25px;color:#f1f7ff;}
            QLabel#metricSubtitle {background:transparent;color:#95a9c3;font-size:11px;}
            QLabel#viewMode {color:#c3d3e9;font-size:12px;font-weight:600;}
            QPushButton:disabled {background:#1b2c41;color:#6c7c92;border:1px solid #2e4057;}
            QLabel#summary {background:#132136;border:1px solid #283b56;border-radius:9px;
                            padding:13px;color:#b6c8e0;}
            QFrame#graphPanel {background:#151d2d;border:1px solid #28374c;border-radius:12px;}
            QLabel#graphTitle {background:transparent;color:#96a8c5;font-weight:700;font-size:11px;}
            QPushButton {border-radius:9px;background:#2b507d;color:#f2f7ff;
                         border:1px solid #476a93;padding:10px 13px;font-weight:700;}
            QPushButton:hover {background:#36689d;}
        )");
        timer_=new QTimer(this);
        connect(timer_,&QTimer::timeout,this,[this]{refresh();});
        timer_->start(1000); refresh();
    }
    // El modo histórico nunca invoca ni modifica el colector en ejecución.
    bool loadCsvPath(const QString &path) {
        QFileInfo info(path);
        if (!info.isFile() || info.size()>25*1024*1024) {
            QMessageBox::warning(this,"CSV","Archivo inexistente o mayor de 25 MiB.");
            return false;
        }
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly|QIODevice::Text)) {
            QMessageBox::warning(this,"CSV","No se pudo abrir el archivo.");
            return false;
        }
        QTextStream input(&file);
        QString header=input.readLine().trimmed();
        const QString expected="timestamp,profile,fan0_rpm,fan1_rpm,cpu_c,acpi_c,gpu_c,gpu_load_pct,gpu_power_w,fan_status";
        header.remove(QChar(0xFEFF));
        if (header != expected) {
            QMessageBox::warning(this,"CSV","Cabecera no compatible con exportaciones de omen-panel.");
            return false;
        }
        QVector<Sample> imported;
        int rejected=0;
        while(!input.atEnd()) {
            const QString line=input.readLine();
            if (line.trimmed().isEmpty()) continue;
            if (line.size()>4096) {++rejected;continue;}
            Sample item;
            if (!parseCsvSample(line,item)) {++rejected;continue;}
            imported.push_back(item);
            if(imported.size()>2400) imported.remove(0,imported.size()-2400);
        }
        if(imported.isEmpty()) {
            QMessageBox::warning(this,"CSV","No se encontraron muestras válidas.");
            return false;
        }
        std::sort(imported.begin(), imported.end(),
                  [](const Sample &a,const Sample &b){return a.when<b.when;});
        history_=std::move(imported);
        historic_=true;
        backLive_->setEnabled(true);
        viewMode_->setText(QString("HISTÓRICO · %1 · %2 muestras · %3 filas rechazadas")
                           .arg(info.fileName()).arg(history_.size()).arg(rejected));
        last_=history_.last();
        renderSample(last_,true);
        updateControlAvailability();
        return true;
    }
protected:
    void resizeEvent(QResizeEvent *ev) override {
        QMainWindow::resizeEvent(ev);
        const int w=ev->size().width();
        const int cols=(w<700?1:(w<1000?2:3));
        if (cols == metricColumns_ || !metrics_) return;
        for (QFrame *widget : metricWidgets_) metrics_->removeWidget(widget);
        for (int i=0; i<metricWidgets_.size(); ++i)
            metrics_->addWidget(metricWidgets_[i],i/cols,i%cols);
        for (int c=0;c<3;++c) metrics_->setColumnStretch(c,c<cols?1:0);
        metricColumns_=cols;
    }
private:
    // State owned by root; display-only, NEVER execute values from this file.
    QString selectedThermalMode() const {
        QFile f("/var/run/omen-power-thermal.state");
        if (!f.open(QIODevice::ReadOnly|QIODevice::Text)) return QString();
        for (const QByteArray &line : f.readAll().split('\n')) {
            if (!line.startsWith("mode=")) continue;
            const QString v=QString::fromUtf8(line.mid(5)).trimmed();
            if (v=="automatic" || v=="manual" || v=="maximum" || v=="error") return v;
        }
        return QString();
    }
    void syncThermalButtons() {
        const QString mode=selectedThermalMode();
        if(emergencyOffButton_) emergencyOffButton_->setChecked(mode=="automatic");
        if(manualButton_) manualButton_->setChecked(mode=="manual");
        if(thermalMaximum_) thermalMaximum_->setChecked(mode=="maximum");
        if(thermalStatus_ && !historic_) {
            if(lastRequestFailed_) {
                thermalStatus_->setText("ULTIMA SOLICITUD FALLIDA: el modo mostrado procede "
                    "del ultimo estado guardado y NO confirma el cambio solicitado. "
                    "Comprueba la conexion con omen-control-client status.");
                return;
            }
            thermalStatus_->setText(mode=="automatic"
              ? "AUTOMATIC solicitado: seleccion dinamica Eco / Balanced / Performance (comprueba que el servicio esté activo). RPM gestionadas por HP."
              : mode=="manual" ? "MANUAL: conserva Power Mode seleccionado. Ventiladores regulados por HP."
              : mode=="maximum" ? "MAXIMUM: FAN MAX persistente hasta nuevo cambio manual (verifica FFFS=1)."
              : mode=="error" ? "ATENCION: ultima operacion no confirmada; comprobar FFFS/RPM."
              : "Thermal Control sin estado persistido tras arranque; selecciona un modo.");
        }
    }
    void updateControlAvailability() {
        // Las RPM son telemetria y pueden llegar a 0 legitimamente. Incluso
        // sin colector, permitir solicitar un modo: el backend root valida
        // ECON, HPCM, sensores, alimentacion y confirmacion HP WMI.
        // La GUI no debe convertir un sensor a 0 o una muestra caducada
        // en un bloqueo de acceso a Power Mode o Thermal Control.
        for (QPushButton *button: controlButtons_)
            // Permitir otro cambio mientras se comprueba la telemetria de uno
            // YA finalizado. El broker protege las escrituras concurrentes.
            button->setEnabled(!controlBusy_);
        syncThermalButtons();
    }
    void requestControl(const QString &category,const QString &value) {
        if (controlBusy_) return;
        // El usuario puede cambiar de modo sin esperar la muestra del colector.
        // Invalidar solo la comprobacion pendiente, nunca una orden en curso.
        if(pendingVerification_) {
            pendingVerification_=false;
            statusBar()->showMessage("Verificacion anterior sustituida por nueva solicitud",4000);
        }
        // Al salir del historial, el readback debe proceder del colector real.
        if (historic_) returnToLive();
        updateControlAvailability();
        if (controlButtons_.isEmpty() || !controlButtons_.first()->isEnabled()) return;
        const QString binary="/usr/local/bin/omen-control-client";
        if (!QFileInfo(binary).isExecutable()) {
            QMessageBox::warning(this,"Servicio de control no instalado",
                "Instala la v0.4.4 y activa omen_control_daemon. La interfaz no solicita contraseñas.");
            return;
        }
        QString details;
        if(category=="power") {
            details="Fija el perfil elegido y cambia Thermal Control a MANUAL. "
                    "Eco usa HP Cool: NO equivale al modo Eco completo de Windows. "
                    "Performance no garantiza ventiladores siempre activos.";
        } else if(value=="automatic") {
            details="Inicia el supervisor: elige Eco/Balanced/Performance por carga de CPU/GPU, "
                    "temperaturas y alimentación; solo cambia tras confirmación y espera mínima. "
                    "Los ventiladores quedan en regulación automática HP.";
        } else if(value=="manual") {
            details="Detiene el supervisor y conserva el perfil de potencia actualmente activo. "
                    "Los ventiladores continúan con la regulación HP; no se fijan RPM.";
        } else {
            details="Activa FAN MAX sin temporizador hasta cambio manual. "
                    "Performance se solicita cuando el preflight lo permite; RPM=0 no bloquea FAN MAX.";
        }
        const QString label=category=="power" ? "Power Mode" : "Thermal Control";
        if(QMessageBox::warning(this,"Confirmar control HP",
            QString("%1: %2\n\n%3\n\nEl backend verificará firmware, temperaturas y estado WMI.\n0 RPM no impedirá solicitar el cambio.")
                 .arg(label,value,details),
            QMessageBox::Yes|QMessageBox::Cancel,QMessageBox::Cancel)!=QMessageBox::Yes) return;
        controlBusy_=true;updateControlAvailability();
        const QDateTime sentAt=QDateTime::currentDateTime();
        // Identificador numerico de esta peticion: permite comprobar que el
        // readback pertenece a la operacion ACTUAL, no a un estado anterior.
        const QString requestId=QString::number(QDateTime::currentMSecsSinceEpoch());
        auto *proc=new QProcess(this);
        activeControl_=proc;
        proc->setProgram(binary);
        // El cliente solo habla con el socket local root:omencontrol.
        // No se ejecuta sudo, kdesu ni pkexec desde Qt.
        proc->setArguments({category,value,requestId});
        statusBar()->showMessage(QString("%1 %2: enviando al servicio local...").arg(label,value));
        connect(proc,&QProcess::errorOccurred,this,[this,proc](QProcess::ProcessError error){
            if(error!=QProcess::FailedToStart || activeControl_!=proc) return;
            controlBusy_=false;
            activeControl_=nullptr;
            updateControlAvailability();
            QMessageBox::critical(this,"Autorización no iniciada",proc->errorString());
            proc->deleteLater();
        });
        connect(proc,QOverload<int,QProcess::ExitStatus>::of(&QProcess::finished),this,
            [this,proc,category,value,sentAt,requestId](int code,QProcess::ExitStatus exitStatus){
                if(activeControl_!=proc) return;
                const QString out=QString::fromUtf8(proc->readAllStandardOutput()).trimmed();
                const QString err=QString::fromUtf8(proc->readAllStandardError()).trimmed();
                const bool helperOk=exitStatus==QProcess::NormalExit && code==0;
                activeControl_=nullptr;
                controlBusy_=false;
                proc->deleteLater();
                // Si el cliente no pudo conectarse (69), fue denegado (77)
                // o ha fallado por otra causa, NO lanzar una verificacion
                // especulativa ni atribuirle el modo guardado de otra orden.
                // Una salida fallida puede ser parcial: solo el readback
                // independiente puede decir que sucedio realmente.
                if(!helperOk) {
                    lastRequestFailed_=true;
                    updateControlAvailability();
                    const QString diag=code==69
                        ? "El socket rechazo esta sesion. Comprueba id -Gn y "
                          "que aparezca omencontrol. Si id -Gn TU_USUARIO "
                          "lo muestra, cierra por completo KDE y vuelve a entrar."
                        : code==77
                        ? "El daemon rechazo la autorizacion o los permisos. "
                          "Comprueba la pertenencia a omencontrol y el log del servicio."
                        : "La orden termino con error; puede haber tenido efectos parciales. "
                          "Comprueba HPCM y FFFS antes de reintentar.";
                    statusBar()->showMessage("Solicitud sin confirmar: fallo del cliente local",20000);
                    QMessageBox::warning(this,"Control HP no confirmado",
                        QString("La solicitud %1 %2 no se ha confirmado. "
                                "El estado anterior no prueba que este cambio se haya aplicado."
                                "\nCodigo de salida: %3\n\n%4\n\n%5\n\n"
                                "Diagnostico: omen-control-client status")
                            .arg(category,value).arg(code).arg(diag,(out+"\n"+err).trimmed().right(2000)));
                    QTimer::singleShot(200,this,[this]{refresh();});
                    return;
                }
                lastRequestFailed_=false;
                // El acuse del broker NO es prueba de que HPCM/FFFS hayan
                // cambiado. Verificar con una muestra NUEVA del colector.
                pendingCategory_=category;
                pendingValue_=value;
                pendingRequestId_=requestId;
                pendingDescription_=(out+"\n"+err).trimmed().right(2400);
                pendingHelperOk_=helperOk;
                pendingHelperExitCode_=code;
                pendingSentAt_=sentAt;
                pendingFinishedAt_=QDateTime::currentDateTime();
                pendingVerification_=true;
                updateControlAvailability();
                statusBar()->showMessage("Leyendo HPCM y FFFS del colector tras la operación...");
                QTimer::singleShot(200,this,[this]{refresh();});
            });
        // Cinturon adicional: nunca mantener la GUI bloqueada por un cliente
        // cuya salida no termina. Maximum ahora responde inmediatamente.
        auto *watchdog=new QTimer(proc);
        watchdog->setSingleShot(true);
        watchdog->setInterval(40000);
        connect(watchdog,&QTimer::timeout,this,[this,proc,category,value]{
            if(activeControl_!=proc) return;
            activeControl_=nullptr;
            controlBusy_=false;
            lastRequestFailed_=true;
            proc->kill(); // solo el cliente; el daemon comprueba su propio plazo
            proc->deleteLater();
            updateControlAvailability();
            statusBar()->showMessage("Tiempo de espera agotado; controles disponibles",20000);
            QMessageBox::warning(this,"Respuesta del servicio pendiente",
                QString("La operacion %1 %2 no ha recibido respuesta dentro del plazo. "
                        "El firmware podria haber cambiado: comprueba HPCM y FFFS "
                        "antes de repetir la orden.\n\n"
                        "Diagnostico: omen-control-client status")
                    .arg(category,value));
        });
        watchdog->start();
        proc->start();
    }
    void endVerification(bool confirmed,const QString &reason) {
        if(!pendingVerification_) return;
        pendingVerification_=false;
        lastRequestFailed_=!confirmed;
        updateControlAvailability();
        const QString details=QString("\nHPCM=%1 · FFFS=%2 · Thermal=%3")
                              .arg(displayInt(last_.hpcm),displayInt(last_.fffs),selectedThermalMode());
        if(confirmed) {
            statusBar()->showMessage("Confirmado mediante telemetría: "+reason,18000);
            QMessageBox::information(this,"Control HP confirmado",reason+details+
               "\n\nLas RPM=0 no bloquean Power Mode ni Thermal Control.");
        }else{
            statusBar()->showMessage("Operación no confirmada: comprueba HPCM/FFFS",20000);
            QMessageBox::warning(this,"Control HP sin confirmar",
                reason+details+"\n\n"+pendingDescription_+
                "\nPara diagnosticar: /usr/local/bin/omen-control-client status");
        }
    }
    QString stateRequestId() const {
        QFile state("/var/run/omen-power-thermal.state");
        if(!state.open(QIODevice::ReadOnly|QIODevice::Text)) return QString();
        for(const QByteArray &line:state.readAll().split('\n')) {
            if(!line.startsWith("request_id=")) continue;
            const QString result=QString::fromLatin1(line.mid(11)).trimmed();
            static const QRegularExpression numeric("^[0-9]{12,20}$");
            return numeric.match(result).hasMatch() ? result : QString();
        }
        return QString();
    }
    void verifyFromNewTelemetry(const Sample &s) {
        if(!pendingVerification_ || !pendingFinishedAt_.isValid()) return;
        // El colector actualiza atomica y periodicamente; no aceptar una
        // muestra anterior al FIN de la solicitud privilegiada.
        if(s.when<=pendingFinishedAt_) return;
        const QString mode=selectedThermalMode();
        bool profileOk=false, thermalOk=false;
        QString expected;
        if(pendingCategory_=="power") {
            const int target=pendingValue_=="eco"?80:(pendingValue_=="balanced"?48:49);
            profileOk=(s.hpcm==target);
            thermalOk=(mode=="manual" && s.fffs==0);
            expected=QString("Power %1").arg(pendingValue_);
        }else if(pendingValue_=="automatic") {
            // Automatic puede cambiar HPCM despues (3 muestras de carga).
            profileOk=(s.hpcm==48 || s.hpcm==49 || s.hpcm==80);
            thermalOk=(mode=="automatic" && s.fffs==0);
            expected="Thermal Automatic";
        }else if(pendingValue_=="manual") {
            profileOk=(s.hpcm==48 || s.hpcm==49 || s.hpcm==80);
            thermalOk=(mode=="manual" && s.fffs==0);
            expected="Thermal Manual";
        }else if(pendingValue_=="maximum") {
            profileOk=(s.hpcm==48 || s.hpcm==49 || s.hpcm==80);
            thermalOk=(mode=="maximum" && s.fffs==1);
            expected="Thermal Maximum persistente";
        }
        // La confirmacion exige acuse identificable del backend privilegiado
        // y telemetria POSTERIOR a terminar el comando, no solo exit code 0.
        const bool receipt=(stateRequestId()==pendingRequestId_);
        if(profileOk && thermalOk && receipt) {
            const QString note=pendingHelperOk_?QString():
                " (cliente informo un error, pero el firmware y el acuse se verificaron)";
            endVerification(true,expected+QString(" · HPCM=%1 · FFFS=%2")
                             .arg(s.hpcm).arg(s.fffs)+note);
        }
    }
    void expireVerification() {
        if(!pendingVerification_ || !pendingFinishedAt_.isValid()) return;
        if(pendingFinishedAt_.secsTo(QDateTime::currentDateTime())<16) return;
        QString explanation=pendingHelperOk_
            ? "El servicio termino correctamente, pero no llego una lectura NUEVA que confirmara el perfil y FFFS."
            : QString("El cliente salio con codigo %1. No se puede asegurar que el backend haya ejecutado el cambio.")
                         .arg(pendingHelperExitCode_);
        endVerification(false,explanation);
    }
    void showBanner(const QString &message,int severity=0) {
        state_->setText(message);
        const char *style = severity==2
            ? "background:#3c232a;color:#ffd4dc;border:1px solid #bc5a6a;"
            : (severity==1
                ? "background:#392e1d;color:#ffe3b8;border:1px solid #b98b47;"
                : "background:#162c32;color:#b6f1e3;border:1px solid #336963;");
        state_->setStyleSheet(QString("QLabel {border-radius:9px;padding:12px;%1}").arg(QString::fromUtf8(style)));
    }
    static QString sensorMessage(const Sample &s, qint64 age) {
        if (s.fanStatus=="CERO_SIN_VALIDAR" || s.fan0==0 || s.fan1==0) {
            const bool relativelyCool=std::isfinite(s.cpu) && std::isfinite(s.acpi) &&
                    s.cpu<=52 && s.acpi<=52 && s.fffs==0;
            return relativelyCool
                ? "0 RPM: posible fan-stop HP, no confirmado. Power Mode y Thermal Control siguen disponibles."
                : "ALERTA: 0 RPM con temperatura/estado a comprobar. Controles disponibles; comprueba flujo de aire y evita carga intensa.";
        }
        if (s.fanStatus=="EC_CERO_WMI_OK")
            return "Aviso: EC devolvio cero; WMI ha recuperado RPM coherentes. Lectura alternativa visible.";
        if (s.fanStatus=="CERO_TRANSITORIO")
            return "Aviso: cero transitorio de EC; la repeticion devolvio RPM. Continua la vigilancia.";
        if (s.fanStatus!="OK")
            return "Aviso: estado de tacometro no reconocido: "+s.fanStatus;
        if (!std::isfinite(s.gpu))
            return "Ventiladores OK. NVIDIA sin datos ("+s.gpuStatus+"). Revisa la ruta del ejecutable y el driver.";
        return QString("Lectura actualizada · %1 s desde la ultima muestra · Solo lectura").arg(age);
    }
    static QFrame* graphCard(const QString &title, QWidget *graph) {
        auto *frame=new QFrame;frame->setObjectName("graphPanel");
        auto *layout=new QVBoxLayout(frame);layout->setContentsMargins(13,14,13,7);
        auto *heading=new QLabel(title);heading->setObjectName("graphTitle");
        layout->addWidget(heading);layout->addWidget(graph);
        return frame;
    }
    void returnToLive() {
        historic_=false;
        backLive_->setEnabled(false);
        updateControlAvailability();
        history_.clear();
        last_=Sample();
        lastModified_=QDateTime();
        viewMode_->setText("DIRECTO · " + source_);
        fan0_.value->setText("—"); fan1_.value->setText("—");
        prof_.value->setText("—"); cpu_.value->setText("—");
        acpi_.value->setText("—");gpu_.value->setText("—");
        summary_->setText("Esperando una muestra actual del colector...");
        tempGraph_->setHistory(history_);fanGraph_->setHistory(history_);
        powerGraph_->setHistory(history_);
        refresh();
    }
    void refresh() {
        expireVerification();
        if(historic_) { updateControlAvailability(); return; }
        QFileInfo fi(source_);
        updateControlAvailability();
        if (!fi.exists() || !fi.isFile()) {
            showBanner("Sin telemetria. Inicia el servicio: sudo service omen_collector onestart, o el colector manual.",1);
            return;
        }
        const qint64 age = fi.lastModified().secsTo(QDateTime::currentDateTime());
        if (age>12 || age< -10) {
            showBanner(QString("Datos desactualizados (%1 s). Comprueba el colector; las cifras que ves son la ultima muestra, NO son actuales.").arg(age),2);
            return;
        }
        if (fi.lastModified()==lastModified_) {
            showBanner(sensorMessage(last_, age), last_.fanStatus=="OK" && last_.fan0>0 && last_.fan1>0 && std::isfinite(last_.gpu) ? 0 :
                       last_.fanStatus=="CERO_SIN_VALIDAR" || last_.fan0==0 || last_.fan1==0 ? 2 : 1);
            return;
        }
        QFile f(source_);
        if (!f.open(QIODevice::ReadOnly|QIODevice::Text)) {
            showBanner("No se puede leer la telemetria: revisa los permisos del colector.",2);return;
        }
        const QByteArray bytes=f.read(8192);f.close();
        Sample s;
        if (!parseOmenStatus(QString::fromUtf8(bytes),s)) {
            showBanner("Datos incompletos. Verifica omenctl v0.3.3 y el colector.",2);return;
        }
        s.when=fi.lastModified();
        // Evita mezclar historiales si se reinicia el colector o retrocede el reloj.
        if (lastModified_.isValid() && s.when < lastModified_) history_.clear();
        lastModified_=s.when; last_=s;
        verifyFromNewTelemetry(s);
        updateControlAvailability();
        history_.push_back(s);
        if(history_.size()>2400) history_.remove(0,history_.size()-2400);
        renderSample(s,false);
    }
    void renderSample(const Sample &s,bool historical) {
        fan0_.value->setText(displayRpm(s.fan0));fan1_.value->setText(displayRpm(s.fan1));
        const QString fanSource = s.fanStatus=="EC_CERO_WMI_OK"
            ? "Tacometro WMI · respaldo tras cero EC"
            : "Tacometro EC";
        fan0_.subtitle->setText(fanSource+" · fan 0");
        fan1_.subtitle->setText(fanSource+" · fan 1");
        const QString powerName=s.hpcm==80 ? "Eco" : (s.hpcm==49 ? "Performance" :
                                 (s.hpcm==48 ? "Balanced" : s.profile));
        prof_.value->setText(powerName);
        prof_.subtitle->setText(s.hpcm==80 ? "HP Cool · HPCM=80 (Eco parcial)" : "HPCM="+displayInt(s.hpcm));
        if(powerEco_) powerEco_->setChecked(s.hpcm==80);
        if(powerBalanced_) powerBalanced_->setChecked(s.hpcm==48);
        if(powerPerformance_) powerPerformance_->setChecked(s.hpcm==49);
        syncThermalButtons();
        if (!historical && thermalStatus_ && selectedThermalMode()=="maximum") {
            if (s.fffs==0) {
                thermalStatus_->setText("ATENCION: MAXIMUM solicitado, pero FFFS=0. "
                    "El firmware no confirma FAN MAX; no se reactivara automaticamente.");
            } else if (s.fffs==1) {
                thermalStatus_->setText("MAXIMUM confirmado: FFFS=1. "
                    "Sin temporizador propio; HP puede revocar la solicitud.");
            }
        }
        cpu_.value->setText(displayTemp(s.cpu));cpu_.subtitle->setText("AMD Ryzen 9 5900HX");
        acpi_.value->setText(displayTemp(s.acpi));acpi_.subtitle->setText("Zona termica del firmware HP");
        gpu_.value->setText(displayTemp(s.gpu));
        gpu_.subtitle->setText(std::isfinite(s.gpu) ?
            "GPU "+displayInt(s.gpuLoad)+" % · "+(std::isfinite(s.power)?QString::number(s.power,'f',1)+" W":"N/D") :
            "Sin datos: "+s.gpuStatus);
        auto rangeText = [this](auto getter,const QString &unit,int prec)->QString {
            double low=std::numeric_limits<double>::infinity();
            double high=-std::numeric_limits<double>::infinity();
            for (const Sample &sample:history_) {
                const double v=getter(sample);
                if (std::isfinite(v) && v>=0) {low=std::min(low,v);high=std::max(high,v);}
            }
            if (!std::isfinite(low)) return "N/D";
            return QString::number(low,'f',prec)+"–"+QString::number(high,'f',prec)+" "+unit;
        };
        const QString f0range=rangeText([](const Sample &x){return double(x.fan0);},"RPM",0);
        const QString f1range=rangeText([](const Sample &x){return double(x.fan1);},"RPM",0);
        const QString cputemp=rangeText([](const Sample &x){return x.cpu;},"°C",1);
        const QString gputemp=rangeText([](const Sample &x){return x.gpu;},"°C",1);
        summary_->setText(QString("SESION   ·   %1 muestras    |    F0 %2    |    F1 %3\n"
                                  "CPU %4    |    NVIDIA %5    |    GPUT %6    ·    SW2S %7    ·    FFFS %8")
                          .arg(history_.size()).arg(f0range).arg(f1range)
                          .arg(cputemp).arg(gputemp)
                          .arg(displayInt(s.gput)).arg(displayInt(s.sw2s)).arg(displayInt(s.fffs)));
        if (historical) {
            const QString missing=std::isfinite(s.gpu) ? QString() : " · NVIDIA sin datos";
            showBanner(QString("HISTÓRICO · datos del %1 al %2%3 · solo lectura")
                     .arg(history_.first().when.toString("yyyy-MM-dd HH:mm:ss"))
                     .arg(history_.last().when.toString("yyyy-MM-dd HH:mm:ss"))
                     .arg(missing),
                       s.fan0==0 || s.fan1==0 || s.fanStatus=="CERO_SIN_VALIDAR" ? 2 : 0);
        } else {
            const bool zeroRpm=(s.fanStatus=="CERO_SIN_VALIDAR" || s.fan0==0 || s.fan1==0);
            const bool coolZero=zeroRpm && std::isfinite(s.cpu) && std::isfinite(s.acpi) &&
                       s.cpu<=52 && s.acpi<=52 && s.fffs==0;
            showBanner(sensorMessage(s, 0), zeroRpm ? (coolZero ? 1 : 2) :
                       (s.fanStatus=="OK" && std::isfinite(s.gpu) ? 0 : 1));
        }
        tempGraph_->setHistory(history_); fanGraph_->setHistory(history_);
        powerGraph_->setHistory(history_);
    }
    void exportHistory() {
        if(history_.isEmpty()) {QMessageBox::information(this,"Exportar","Aun no hay muestras.");return;}
        const QString path=QFileDialog::getSaveFileName(this,"Guardar historial", "omen-thermal.csv", "CSV (*.csv)");
        if(path.isEmpty()) return;
        QFile f(path);
        if(!f.open(QIODevice::WriteOnly|QIODevice::Text|QIODevice::Truncate)) {
            QMessageBox::warning(this,"Error","No se puede guardar el archivo.");return;
        }
        QTextStream out(&f);
        out<<"timestamp,profile,fan0_rpm,fan1_rpm,cpu_c,acpi_c,gpu_c,gpu_load_pct,gpu_power_w,fan_status\n";
        auto val=[](double d){return std::isfinite(d)?QString::number(d,'f',1):QString();};
        for (const Sample &s : history_) {
            out<<s.when.toString(Qt::ISODate)<<","<<(s.hpcm==80 ? QString("Eco") : s.profile)<<","<<s.fan0<<","<<s.fan1<<","<<val(s.cpu)<<","<<val(s.acpi)<<","<<val(s.gpu)<<","<<displayInt(s.gpuLoad)<<","<<val(s.power)<<","<<s.fanStatus<<"\n";
        }
        f.close();
    }
    QString source_;
    QVector<QPushButton*> controlButtons_;
    QPushButton *emergencyOffButton_=nullptr;
    QPushButton *powerEco_=nullptr,*powerBalanced_=nullptr,*powerPerformance_=nullptr;
    QPushButton *thermalMaximum_=nullptr,*manualButton_=nullptr;
    QComboBox *manualSeconds_=nullptr;
    QLabel *powerHint_=nullptr,*thermalStatus_=nullptr;
    bool controlBusy_=false;
    bool pendingVerification_=false;
    bool lastRequestFailed_=false;
    bool pendingHelperOk_=false;
    int pendingHelperExitCode_=-1;
    QString pendingCategory_,pendingValue_,pendingDescription_,pendingRequestId_;
    QDateTime pendingSentAt_,pendingFinishedAt_;
    QProcess *activeControl_=nullptr;
    bool historic_=false;
    QLabel *viewMode_=nullptr;
    QPushButton *backLive_=nullptr;
    QTimer *timer_=nullptr;
    QDateTime lastModified_;
    Sample last_;
    QVector<Sample> history_;
    QLabel *state_=nullptr,*summary_=nullptr;
    Metric fan0_,fan1_,prof_,cpu_,acpi_,gpu_;
    QGridLayout *metrics_=nullptr;
    QVector<QFrame*> metricWidgets_;
    int metricColumns_=3;
    TrendGraph *tempGraph_=nullptr,*fanGraph_=nullptr,*powerGraph_=nullptr;
};

int main(int argc,char **argv) {
    QApplication app(argc,argv);
    const QStringList args=app.arguments();
    if (args.contains("--help")) {
        QTextStream(stdout)<<"Uso: omen-panel [--file RUTA] [--csv ARCHIVO.csv]\n"
            "Normalmente lee /var/run/omenctl/status (requiere colector)\n"
            "Nunca requiere privilegios de root.\n";
        return 0;
    }
    QString source="/var/run/omenctl/status";
    const int idx=args.indexOf("--file");
    if (idx>=0) {
        if(idx+1>=args.size()) { QTextStream(stderr)<<"Falta ruta tras --file\n";return 2; }
        source=args[idx+1];
    }
    Dashboard window(source);
    const int csvIndex=args.indexOf("--csv");
    if (csvIndex>=0 && csvIndex+1>=args.size()) {
        QTextStream(stderr)<<"Falta ruta tras --csv\n";return 2;
    }
    window.show();
    if (csvIndex>=0) window.loadCsvPath(args[csvIndex+1]);
    return app.exec();
}
