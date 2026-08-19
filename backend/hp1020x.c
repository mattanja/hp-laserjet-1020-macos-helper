// hp1020x: native macOS CUPS USB backend for the HP LaserJet 1020.
//
// Adapted from Kuberwastaken/hp-laser-1008a-macos (IOKit seize + classic
// printer-class alt setting). This variant matches only the LaserJet 1020
// (VID 0x03F0 PID 0x2B17) so it cannot steal other HP devices on the bus,
// and it uploads sihp1020.dl after a USB reconnect (the 1020 has no
// persistent firmware).
//
// Build: clang -O2 -o hp1020x hp1020x.c -framework IOKit -framework CoreFoundation
//        -Wno-deprecated-declarations
//
// Usage (as CUPS backend /usr/libexec/cups/backend/hp1020x):
//   hp1020x                discovery
//   hp1020x probe          dump USB config descriptor (needs root)
//   hp1020x <file>         one-shot write
//   hp1020x job ...        CUPS print (job on stdin or argv[6])

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define HP_VID          0x03F0
#define HP_PID_1020     0x2B17
#define FIRMWARE_PATH_1 "/Library/Printers/hp/laserjet/hp1020/sihp1020.dl"
#define FIRMWARE_PATH_2 "/usr/local/share/foo2zjs/firmware/sihp1020.dl"
#define SESSION_PATH    "/Library/Printers/hp/laserjet/hp1020/.usb-session"
#define WRITE_CHUNK     (64 * 1024)
#define FIRMWARE_WAIT_S 5

static int g_backend = 0;

static void logmsg(const char *fmt, ...) {
    va_list ap;
    if (g_backend) {
        fputs("DEBUG: hp1020x: ", stderr);
        va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
        fputc('\n', stderr); fflush(stderr);
        return;
    }
    fprintf(stderr, "hp1020x: ");
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}

static int is_1020_pid(UInt16 pid) {
    return pid == HP_PID_1020;
}

typedef struct {
    IOUSBDeviceInterface **dev;
    uint64_t session;
} FoundDev;

static FoundDev find_device(void) {
    FoundDev out = {0};
    const char *classes[] = { "IOUSBHostDevice", kIOUSBDeviceClassName };
    for (int ci = 0; ci < 2; ci++) {
        CFMutableDictionaryRef match = IOServiceMatching(classes[ci]);
        if (!match) continue;
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS)
            continue;
        io_service_t svc;
        while ((svc = IOIteratorNext(iter))) {
            IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
            IOUSBDeviceInterface **dev = NULL;
            if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                    kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS && plugin) {
                (*plugin)->QueryInterface(plugin,
                    CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
                (*plugin)->Release(plugin);
            }
            if (dev) {
                UInt16 vid = 0, pid = 0;
                (*dev)->GetDeviceVendor(dev, &vid);
                (*dev)->GetDeviceProduct(dev, &pid);
                if (vid == HP_VID && is_1020_pid(pid)) {
                    CFTypeRef sid = IORegistryEntryCreateCFProperty(
                        svc, CFSTR("sessionID"), kCFAllocatorDefault, 0);
                    if (sid && CFGetTypeID(sid) == CFNumberGetTypeID())
                        CFNumberGetValue((CFNumberRef)sid, kCFNumberSInt64Type, &out.session);
                    if (sid) CFRelease(sid);
                    logmsg("found %04x:%04x session=%llu via %s",
                           vid, pid, (unsigned long long)out.session, classes[ci]);
                    IOObjectRelease(svc);
                    IOObjectRelease(iter);
                    out.dev = dev;
                    return out;
                }
                (*dev)->Release(dev);
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }
    return out;
}

static int find_classic_iface(IOUSBDeviceInterface **dev, UInt8 *ifaceNum, UInt8 *alt) {
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg) != kIOReturnSuccess || !cfg) return 0;
    const unsigned char *p = (const unsigned char *)cfg;
    int total = p[2] | (p[3] << 8);
    int curCls = -1, curProto = -1; UInt8 curIf = 0, curAlt = 0;
    for (int i = 0; i + 2 <= total; ) {
        int len = p[i], type = p[i + 1];
        if (len == 0) break;
        if (type == 4 && i + 9 <= total) {
            curIf = p[i + 2]; curAlt = p[i + 3]; curCls = p[i + 5]; curProto = p[i + 7];
        } else if (type == 5 && i + 6 <= total) {
            int addr = p[i + 2], isBulk = (p[i + 3] & 3) == 2, isOut = !(addr & 0x80);
            if (curCls == 7 && (curProto == 1 || curProto == 2) && isBulk && isOut) {
                *ifaceNum = curIf; *alt = curAlt; return 1;
            }
        }
        i += len;
    }
    return 0;
}

static IOUSBInterfaceInterface **open_printer_interface(IOUSBDeviceInterface **dev, UInt8 *pipeOut) {
    (*dev)->USBDeviceOpenSeize(dev);

    UInt8 wantIf = 0, wantAlt = 0;
    int haveTarget = find_classic_iface(dev, &wantIf, &wantAlt);
    if (haveTarget) logmsg("classic printer iface = num %u alt %u", wantIf, wantAlt);
    else            logmsg("no classic iface in config descriptor; falling back to proto match");

    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t iter = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &iter) != kIOReturnSuccess) return NULL;

    IOUSBInterfaceInterface **result = NULL;
    io_service_t usbIf;
    while ((usbIf = IOIteratorNext(iter))) {
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOUSBInterfaceInterface **intf = NULL;
        if (IOCreatePlugInInterfaceForService(usbIf, kIOUSBInterfaceUserClientTypeID,
                kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS && plugin) {
            (*plugin)->QueryInterface(plugin,
                CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
            (*plugin)->Release(plugin);
        }
        IOObjectRelease(usbIf);
        if (!intf) continue;

        UInt8 cls = 0, proto = 0, altNum = 0, ifNum = 0;
        (*intf)->GetInterfaceClass(intf, &cls);
        (*intf)->GetInterfaceProtocol(intf, &proto);
        (*intf)->GetAlternateSetting(intf, &altNum);
        (*intf)->GetInterfaceNumber(intf, &ifNum);
        logmsg("iface num=%u class=%u proto=%u alt=%u", ifNum, cls, proto, altNum);

        int isTarget = haveTarget ? (ifNum == wantIf) : (cls == 7 && (proto == 1 || proto == 2));
        if (isTarget) {
            IOReturn ir = (*intf)->USBInterfaceOpenSeize(intf);
            if (ir == kIOReturnSuccess) {
                UInt8 useAlt = haveTarget ? wantAlt : altNum;
                IOReturn ar = (*intf)->SetAlternateInterface(intf, useAlt);
                logmsg("SetAlternateInterface(%u) -> 0x%08x", useAlt, ar);
                UInt8 n = 0; (*intf)->GetNumEndpoints(intf, &n);
                for (UInt8 pipe = 1; pipe <= n; pipe++) {
                    UInt8 dir = 0, num = 0, tt = 0, interval = 0; UInt16 mps = 0;
                    (*intf)->GetPipeProperties(intf, pipe, &dir, &num, &tt, &mps, &interval);
                    if (dir == kUSBOut && tt == kUSBBulk) {
                        *pipeOut = pipe; result = intf;
                        logmsg("using bulk-out pipe %u (ep 0x%02x) on iface %u alt %u",
                               pipe, num, ifNum, useAlt);
                        break;
                    }
                }
                if (result) break;
                (*intf)->USBInterfaceClose(intf);
            } else {
                logmsg("seize failed 0x%08x", ir);
            }
        }
        (*intf)->Release(intf);
    }
    IOObjectRelease(iter);
    return result;
}

static int write_pipe_all(IOUSBInterfaceInterface **intf, UInt8 pipe,
                          const unsigned char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        UInt32 n = (UInt32)((len - off) > WRITE_CHUNK ? WRITE_CHUNK : (len - off));
        IOReturn r = (*intf)->WritePipe(intf, pipe, (void *)(data + off), n);
        if (r != kIOReturnSuccess) {
            logmsg("WritePipe failed 0x%08x at %zu/%zu", r, off, len);
            return 1;
        }
        off += n;
    }
    return 0;
}

static void close_dev(FoundDev *fd, IOUSBInterfaceInterface **intf) {
    if (intf) {
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
    }
    if (fd && fd->dev) {
        (*fd->dev)->USBDeviceClose(fd->dev);
        (*fd->dev)->Release(fd->dev);
        fd->dev = NULL;
    }
}

static int usb_write(const unsigned char *data, size_t len) {
    for (int attempt = 1; attempt <= 5; attempt++) {
        FoundDev fd = find_device();
        if (!fd.dev) { logmsg("printer not found; waiting..."); sleep(2); continue; }
        UInt8 pipe = 0;
        IOUSBInterfaceInterface **intf = open_printer_interface(fd.dev, &pipe);
        if (!intf) {
            logmsg("no classic bulk-out interface (attempt %d)", attempt);
            close_dev(&fd, NULL);
            sleep(2);
            continue;
        }
        int rc = write_pipe_all(intf, pipe, data, len);
        if (!rc) logmsg("wrote %zu bytes (pipe %u)", len, pipe);
        close_dev(&fd, intf);
        if (!rc) return 0;
        sleep(2);
    }
    logmsg("giving up after retries");
    return 1;
}

static unsigned char *read_file(const char *path, size_t *outlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return NULL; }
    unsigned char *buf = malloc((size_t)st.st_size);
    if (!buf) { close(fd); return NULL; }
    size_t got = 0;
    while (got < (size_t)st.st_size) {
        ssize_t n = read(fd, buf + got, (size_t)st.st_size - got);
        if (n <= 0) { free(buf); close(fd); return NULL; }
        got += (size_t)n;
    }
    close(fd);
    *outlen = got;
    return buf;
}

static uint64_t load_saved_session(void) {
    FILE *f = fopen(SESSION_PATH, "r");
    if (!f) return 0;
    unsigned long long v = 0;
    if (fscanf(f, "%llu", &v) != 1) v = 0;
    fclose(f);
    return (uint64_t)v;
}

static void save_session(uint64_t session) {
    FILE *f = fopen(SESSION_PATH, "w");
    if (!f) {
        logmsg("could not write session stamp %s (sandbox?)", SESSION_PATH);
        return;
    }
    fprintf(f, "%llu\n", (unsigned long long)session);
    fclose(f);
}

static int looks_like_firmware(const unsigned char *data, size_t len) {
    if (len < 4) return 0;
    if (data[0] == 0xbe && data[1] == 0xef) return 1; /* arm2hpdl HP header */
    /* ACL firmware via PJL, not a print job */
    if (len > 40 && memcmp(data, "\033%-12345X@PJL ENTER LANGUAGE=ACL", 32) == 0)
        return 1;
    return 0;
}

static int looks_like_zjs_job(const unsigned char *data, size_t len) {
    const char *pjl = "\033%-12345X@PJL JOB";
    size_t n = strlen(pjl);
    return len >= n && memcmp(data, pjl, n) == 0;
}

static int maybe_upload_firmware(void) {
    FoundDev fd = find_device();
    if (!fd.dev) {
        logmsg("firmware: printer not found");
        return 1;
    }
    uint64_t saved = load_saved_session();
    if (fd.session && saved == fd.session) {
        logmsg("firmware already sent for USB session %llu",
               (unsigned long long)fd.session);
        (*fd.dev)->Release(fd.dev);
        return 0;
    }
    (*fd.dev)->Release(fd.dev);

    size_t flen = 0;
    unsigned char *fw = read_file(FIRMWARE_PATH_1, &flen);
    if (!fw) fw = read_file(FIRMWARE_PATH_2, &flen);
    if (!fw) {
        logmsg("firmware file missing (%s or %s)", FIRMWARE_PATH_1, FIRMWARE_PATH_2);
        return 1;
    }
    logmsg("uploading firmware (%zu bytes) for new USB session %llu",
           flen, (unsigned long long)fd.session);
    int rc = usb_write(fw, flen);
    free(fw);
    if (rc) return rc;

    logmsg("waiting %ds for printer to accept firmware", FIRMWARE_WAIT_S);
    sleep(FIRMWARE_WAIT_S);

    FoundDev again = find_device();
    if (again.dev) {
        save_session(again.session ? again.session : fd.session);
        (*again.dev)->Release(again.dev);
    } else {
        save_session(fd.session);
    }
    return 0;
}

static int usb_probe(void) {
    FoundDev fd = find_device();
    if (!fd.dev) { printf("HP LaserJet 1020 not found (run with sudo)\n"); return 1; }
    UInt8 nconf = 0; (*fd.dev)->GetNumberOfConfigurations(fd.dev, &nconf);
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*fd.dev)->GetConfigurationDescriptorPtr(fd.dev, 0, &cfg) != kIOReturnSuccess || !cfg) {
        printf("cannot read config descriptor\n"); (*fd.dev)->Release(fd.dev); return 1;
    }
    const unsigned char *p = (const unsigned char *)cfg;
    int total = p[2] | (p[3] << 8);
    printf("HP LaserJet 1020  session=%llu  configs=%u  bNumInterfaces=%u  wTotalLength=%d\n",
           (unsigned long long)fd.session, nconf, p[4], total);
    for (int i = 0; i + 2 <= total; ) {
        int len = p[i], type = p[i + 1];
        if (len == 0) break;
        if (type == 4 && i + 9 <= total)
            printf("  IFACE num=%u alt=%u  class=%u sub=%u proto=%u  nEndpoints=%u\n",
                   p[i+2], p[i+3], p[i+5], p[i+6], p[i+7], p[i+4]);
        else if (type == 5 && i + 6 <= total) {
            int addr = p[i+2], attr = p[i+3] & 3;
            const char *tt = attr==2?"bulk":attr==3?"intr":attr==1?"iso":"ctrl";
            printf("      EP 0x%02x %-3s %s\n", addr, (addr & 0x80) ? "IN" : "OUT", tt);
        }
        i += len;
    }
    (*fd.dev)->Release(fd.dev);
    return 0;
}

static unsigned char *read_all(int fd, size_t *outlen) {
    size_t cap = 1 << 20, len = 0;
    unsigned char *buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (len == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n <= 0) break;
        len += (size_t)n;
    }
    *outlen = len;
    return buf;
}

static int deliver_job(const unsigned char *data, size_t len) {
    if (!data || !len) return 1;
    if (looks_like_firmware(data, len)) {
        logmsg("raw firmware job (%zu bytes)", len);
        int rc = usb_write(data, len);
        if (!rc) {
            FoundDev fd = find_device();
            if (fd.dev) {
                save_session(fd.session);
                (*fd.dev)->Release(fd.dev);
            }
        }
        return rc;
    }
    if (looks_like_zjs_job(data, len) || len > 0) {
        if (maybe_upload_firmware() != 0)
            logmsg("firmware upload failed; trying job anyway");
        return usb_write(data, len);
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && (!strcmp(argv[1], "probe") || !strcmp(argv[1], "--probe")))
        return usb_probe();

    const char *uri = getenv("DEVICE_URI");
    int as_backend = strstr(argv[0], "hp1020x") != NULL ||
                     (uri && strstr(uri, "hp1020x") != NULL);
    // CUPS backend: argc==1 discovery, argc>=6 print job.
    // argc==2 is probe/one-shot even when the binary is named hp1020x.
    if (as_backend && (argc == 1 || argc >= 6)) {
        g_backend = 1;
        if (argc == 1) {
            printf("direct hp1020x:/ \"HP LaserJet 1020\" \"HP LaserJet 1020 (native IOKit)\" "
                   "\"MFG:Hewlett-Packard;MDL:HP LaserJet 1020;CMD:ZJS,ACL;\"\n");
            return 0;
        }
        int infd = 0;
        if (argc >= 7 && argv[6][0]) {
            infd = open(argv[6], O_RDONLY);
            if (infd < 0) { logmsg("cannot open %s", argv[6]); return 1; }
        }
        size_t len = 0;
        unsigned char *data = read_all(infd, &len);
        if (infd) close(infd);
        logmsg("backend job: %zu bytes", len);
        int rc = deliver_job(data, len);
        free(data);
        return rc ? 1 : 0;
    }

    if (argc == 2) {
        size_t len = 0;
        unsigned char *d = read_file(argv[1], &len);
        if (!d) { perror("open"); return 2; }
        int rc = deliver_job(d, len);
        free(d);
        return rc;
    }

    fprintf(stderr, "Usage: %s [probe | <file>]\n", argv[0]);
    return 2;
}
