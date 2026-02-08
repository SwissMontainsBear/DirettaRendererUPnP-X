/**
 * @file main.cpp
 * @brief Main entry point for Diretta UPnP Renderer (Simplified Architecture)
 */

#include "DirettaRenderer.h"
#include "DirettaSync.h"
#include "DirettaProbe.h"
#include <iostream>
#include <csignal>
#include <memory>
#include <thread>
#include <chrono>
#include <fstream>
#include <ctime>

#ifdef DIRETTA_PROBE
#include <sys/utsname.h>
#endif

#define RENDERER_VERSION "2.1-beta"
#define RENDERER_BUILD_DATE __DATE__
#define RENDERER_BUILD_TIME __TIME__

std::unique_ptr<DirettaRenderer> g_renderer;

bool g_verbose = false;

// Async logging infrastructure (A3 optimization)
LogRing* g_logRing = nullptr;
std::atomic<bool> g_logDrainStop{false};
std::thread g_logDrainThread;

#ifdef DIRETTA_PROBE
// Probe infrastructure
ProbeRing* g_probeRing = nullptr;
static std::atomic<bool> g_probeDrainStop{false};
static std::thread g_probeDrainThread;
static std::string g_probeFilePath;
static std::ofstream g_probeFile;

static std::string getDefaultProbeFilePath() {
    auto now = std::chrono::system_clock::now();
    auto t = std::chrono::system_clock::to_time_t(now);
    struct tm tm;
    localtime_r(&t, &tm);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "/tmp/diretta-probe-%04d%02d%02d-%02d%02d%02d.csv",
                  tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                  tm.tm_hour, tm.tm_min, tm.tm_sec);
    return std::string(buf);
}

static void writeProbeHeader(std::ostream& os) {
    struct utsname uts;
    uname(&uts);

    // Read CPU model from /proc/cpuinfo
    std::string cpuModel = "unknown";
    std::ifstream cpuinfo("/proc/cpuinfo");
    if (cpuinfo.is_open()) {
        std::string line;
        while (std::getline(cpuinfo, line)) {
            if (line.find("model name") != std::string::npos) {
                auto pos = line.find(':');
                if (pos != std::string::npos) {
                    cpuModel = line.substr(pos + 2);
                }
                break;
            }
        }
    }

    auto epoch = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();

    os << "# DPROBE1\n";
    os << "# platform: " << uts.machine << "\n";
    os << "# kernel: " << uts.release << "\n";
    os << "# cpu_model: " << cpuModel << "\n";
    os << "# build_date: " << RENDERER_BUILD_DATE << " " << RENDERER_BUILD_TIME << "\n";
#ifdef NOLOG
    os << "# build_flags: NOLOG\n";
#else
    os << "# build_flags: (default)\n";
#endif
    os << "# epoch_ns: " << epoch << "\n";
    os << "# version: " << RENDERER_VERSION << "\n";
    os << "#\n";
    os << "timestamp_ns,event_type,flags,duration_ns,ring_level,ring_capacity,payload\n";
}

static const char* probeEventName(uint16_t type) {
    switch (static_cast<ProbeEventType>(type)) {
        case ProbeEventType::GET_STREAM:          return "GET_STREAM";
        case ProbeEventType::GET_STREAM_UNDERRUN: return "GET_STREAM_UNDERRUN";
        case ProbeEventType::GET_STREAM_SILENCE:  return "GET_STREAM_SILENCE";
        case ProbeEventType::SEND_AUDIO:          return "SEND_AUDIO";
        case ProbeEventType::SEND_AUDIO_FULL:     return "SEND_AUDIO_FULL";
        case ProbeEventType::FORMAT_CHANGE:       return "FORMAT_CHANGE";
        case ProbeEventType::PREFILL_DONE:        return "PREFILL_DONE";
        case ProbeEventType::SESSION_START:       return "SESSION_START";
        case ProbeEventType::SESSION_END:         return "SESSION_END";
        default:                                  return "UNKNOWN";
    }
}

static void drainProbeEvents(std::ostream& os) {
    ProbeEvent event;
    while (g_probeRing && g_probeRing->pop(event)) {
        os << event.timestamp_ns << ","
           << probeEventName(event.event_type) << ","
           << event.flags << ","
           << event.duration_ns << ","
           << event.ring_level << ","
           << event.ring_capacity << ","
           << event.payload << "\n";
    }
}

static void probeDrainThreadFunc() {
    while (!g_probeDrainStop.load(std::memory_order_acquire)) {
        drainProbeEvents(g_probeFile);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    // Final drain on shutdown
    drainProbeEvents(g_probeFile);
}

static void probeShutdown() {
    if (!g_probeRing) return;

    g_probeDrainStop.store(true, std::memory_order_release);
    if (g_probeDrainThread.joinable()) {
        g_probeDrainThread.join();
    }

    // Write dropped event count as a footer comment
    uint64_t dropped = g_probeRing->dropped();
    if (dropped > 0) {
        g_probeFile << "# dropped_events: " << dropped << "\n";
    }

    g_probeFile.flush();
    g_probeFile.close();

    std::cout << "[Probe] Wrote " << g_probeFilePath << std::endl;
    if (dropped > 0) {
        std::cout << "[Probe] Warning: " << dropped << " events dropped (ring full)" << std::endl;
    }

    delete g_probeRing;
    g_probeRing = nullptr;
}
#endif  // DIRETTA_PROBE

void signalHandler(int signal) {
    std::cout << "\nSignal " << signal << " received, shutting down..." << std::endl;
    if (g_renderer) {
        g_renderer->stop();
    }
#ifdef DIRETTA_PROBE
    probeShutdown();
#endif
    exit(0);
}

void logDrainThreadFunc() {
    LogEntry entry;
    while (!g_logDrainStop.load(std::memory_order_acquire)) {
        // Drain all pending log entries
        while (g_logRing && g_logRing->pop(entry)) {
            std::cout << "[" << (entry.timestamp_us / 1000) << "ms] "
                      << entry.message << std::endl;
        }
        // Sleep briefly to avoid busy-wait
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    // Final drain on shutdown
    while (g_logRing && g_logRing->pop(entry)) {
        std::cout << "[" << (entry.timestamp_us / 1000) << "ms] "
                  << entry.message << std::endl;
    }
}

void listTargets() {
    std::cout << "════════════════════════════════════════════════════════\n"
              << "  Scanning for Diretta Targets...\n"
              << "════════════════════════════════════════════════════════\n" << std::endl;

    DirettaSync::listTargets();

    std::cout << "\nUsage:\n";
    std::cout << "   Target #1: sudo ./bin/DirettaRendererUPnP --target 1\n";
    std::cout << "   Target #2: sudo ./bin/DirettaRendererUPnP --target 2\n";
    std::cout << std::endl;
}

#ifdef DIRETTA_PROBE
bool g_probeEnabled = false;
#endif

DirettaRenderer::Config parseArguments(int argc, char* argv[]) {
    DirettaRenderer::Config config;

    config.name = "Diretta Renderer";
    config.port = 0;
    config.gaplessEnabled = true;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];

        if ((arg == "--name" || arg == "-n") && i + 1 < argc) {
            config.name = argv[++i];
        }
        else if ((arg == "--port" || arg == "-p") && i + 1 < argc) {
            config.port = std::atoi(argv[++i]);
        }
        else if (arg == "--uuid" && i + 1 < argc) {
            config.uuid = argv[++i];
        }
        else if (arg == "--no-gapless") {
            config.gaplessEnabled = false;
        }
        else if ((arg == "--target" || arg == "-t") && i + 1 < argc) {
            config.targetIndex = std::atoi(argv[++i]) - 1;
            if (config.targetIndex < 0) {
                std::cerr << "Invalid target index. Must be >= 1" << std::endl;
                exit(1);
            }
        }
        else if (arg == "--interface" && i + 1 < argc) {
            config.networkInterface = argv[++i];
        }
        else if (arg == "--list-targets" || arg == "-l") {
            listTargets();
            exit(0);
        }
        else if (arg == "--version" || arg == "-V") {
            std::cout << "═══════════════════════════════════════════════════════" << std::endl;
            std::cout << "  Diretta UPnP Renderer - Version " << RENDERER_VERSION << std::endl;
            std::cout << "═══════════════════════════════════════════════════════" << std::endl;
            std::cout << "Build: " << RENDERER_BUILD_DATE << " " << RENDERER_BUILD_TIME << std::endl;
            std::cout << "Architecture: Simplified (DirettaSync unified)" << std::endl;
            std::cout << "═══════════════════════════════════════════════════════" << std::endl;
            exit(0);
        }
        else if (arg == "--verbose" || arg == "-v") {
            g_verbose = true;
            std::cout << "Verbose mode enabled" << std::endl;
        }
#ifdef DIRETTA_PROBE
        else if (arg == "--probe") {
            g_probeEnabled = true;
        }
        else if (arg == "--probe-file" && i + 1 < argc) {
            g_probeFilePath = argv[++i];
            g_probeEnabled = true;
        }
#endif
        else if (arg == "--help" || arg == "-h") {
            std::cout << "Diretta UPnP Renderer (Simplified Architecture)\n\n"
                      << "Usage: " << argv[0] << " [options]\n\n"
                      << "Options:\n"
                      << "  --name, -n <name>     Renderer name (default: Diretta Renderer)\n"
                      << "  --port, -p <port>     UPnP port (default: auto)\n"
                      << "  --uuid <uuid>         Device UUID (default: auto-generated)\n"
                      << "  --no-gapless          Disable gapless playback\n"
                      << "  --target, -t <index>  Select Diretta target by index (1, 2, 3...)\n"
                      << "  --interface <name>    Network interface to bind (e.g., eth0)\n"
                      << "  --list-targets, -l    List available Diretta targets and exit\n"
                      << "  --verbose, -v         Enable verbose debug output\n"
                      << "  --version, -V         Show version information\n"
#ifdef DIRETTA_PROBE
                      << "  --probe               Enable instrumentation probes\n"
                      << "  --probe-file <path>   Probe output file (default: /tmp/diretta-probe-*.csv)\n"
#endif
                      << "  --help, -h            Show this help\n"
                      << std::endl;
            exit(0);
        }
        else {
            std::cerr << "Unknown option: " << arg << std::endl;
            std::cerr << "Use --help for usage information" << std::endl;
            exit(1);
        }
    }

    return config;
}

int main(int argc, char* argv[]) {
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    std::cout << "═══════════════════════════════════════════════════════\n"
              << "  Diretta UPnP Renderer v" << RENDERER_VERSION << "\n"
              << "═══════════════════════════════════════════════════════\n"
              << std::endl;

    DirettaRenderer::Config config = parseArguments(argc, argv);

    // Initialize async logging ring buffer (A3 optimization)
    // Only active in verbose mode to avoid overhead in production
    if (g_verbose) {
        g_logRing = new LogRing();
        g_logDrainThread = std::thread(logDrainThreadFunc);
    }

#ifdef DIRETTA_PROBE
    // Initialize probe instrumentation
    if (g_probeEnabled) {
        if (g_probeFilePath.empty()) {
            g_probeFilePath = getDefaultProbeFilePath();
        }

        g_probeFile.open(g_probeFilePath, std::ios::out | std::ios::trunc);
        if (!g_probeFile.is_open()) {
            std::cerr << "[Probe] ERROR: Cannot open " << g_probeFilePath << std::endl;
            return 1;
        }

        g_probeRing = new ProbeRing();
        writeProbeHeader(g_probeFile);
        g_probeDrainThread = std::thread(probeDrainThreadFunc);

        std::cout << "[Probe] Instrumentation enabled -> " << g_probeFilePath << std::endl;
    }
#endif

    std::cout << "Configuration:" << std::endl;
    std::cout << "  Name:     " << config.name << std::endl;
    std::cout << "  Port:     " << (config.port == 0 ? "auto" : std::to_string(config.port)) << std::endl;
    std::cout << "  Gapless:  " << (config.gaplessEnabled ? "enabled" : "disabled") << std::endl;
    if (!config.networkInterface.empty()) {
        std::cout << "  Network:  " << config.networkInterface << std::endl;
    }
    std::cout << "  UUID:     " << config.uuid << std::endl;
    std::cout << std::endl;

    try {
        g_renderer = std::make_unique<DirettaRenderer>(config);

        std::cout << "Starting renderer..." << std::endl;

        if (!g_renderer->start()) {
            std::cerr << "Failed to start renderer" << std::endl;
            return 1;
        }

        std::cout << "Renderer started!" << std::endl;
        std::cout << std::endl;
        std::cout << "Waiting for UPnP control points..." << std::endl;
        std::cout << "(Press Ctrl+C to stop)" << std::endl;
        std::cout << std::endl;

        while (g_renderer->isRunning()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }

    } catch (const std::exception& e) {
        std::cerr << "Exception: " << e.what() << std::endl;
        return 1;
    }

    std::cout << "\nRenderer stopped" << std::endl;

#ifdef DIRETTA_PROBE
    probeShutdown();
#endif

    // Shutdown async logging (A3 optimization cleanup)
    if (g_logRing) {
        g_logDrainStop.store(true, std::memory_order_release);
        if (g_logDrainThread.joinable()) {
            g_logDrainThread.join();
        }
        delete g_logRing;
        g_logRing = nullptr;
    }

    return 0;
}
