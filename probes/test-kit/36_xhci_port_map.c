// Map each USB host-controller port to its physical USB-C port number and
// locationID, so a USB device can be tied to the physical port it sits on.
//
// Why this exists: WhatCable correlates a connected USB device to its physical
// port today with string matching plus a bus index, which has documented edge
// cases. The macOS USB topology key `locationID` is shared across the whole USB
// device stack (host device, interface, hub, and the host-controller port), so
// a device can be tied to its host-controller port reliably:
//
//     IOUSBHostDevice.locationID  ->  AppleUSB*XHCIARMPort.locationID  (same base)
//
// The host-controller port also carries `usb-c-port-number`, the physical port
// index from the USB subsystem's point of view. IMPORTANT: this is NOT
// guaranteed to equal the HPM `Port-USB-C@N` number; the two subsystems can
// number the same physical ports differently (seen on M3+: XHCI 1/2/3 vs HPM
// @1/@2/@4). So this probe captures both numbering schemes as raw data; the
// real XHCI<->HPM correlation has to be worked out by comparing this probe with
// probe 35, not assumed. Probe 35 closes the power->port half (HPM UUID == SMC
// DxUI); this probe captures the device->port half plus the numbering data
// needed to bridge to the HPM side (the XHCI port tree is in no other probe).
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 36_xhci_port_map 36_xhci_port_map.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// usb-c-port-number is stored as little-endian CFData (e.g. <01000000> = 1).
// Handle the CFNumber form too, defensively. Returns -1 if absent/unreadable.
static long long readPortNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = -1;
    if (v) {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(v);
            const UInt8 *b = CFDataGetBytePtr(v);
            out = 0;
            for (CFIndex i = 0; i < len && i < 8; i++) {
                out |= ((long long)b[i]) << (8 * i);
            }
        } else if (t == CFNumberGetTypeID()) {
            CFNumberGetValue(v, kCFNumberLongLongType, &out);
        }
        CFRelease(v);
    }
    return out;
}

// Read a CFNumber property as long long. Returns -1 if absent.
static long long readNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberLongLongType, &out);
    }
    if (v) CFRelease(v);
    return out;
}

// Copy a CFString property into buf. Returns 1 on success.
static int readString(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Print the host-controller ports for one class: name, physical USB-C port
// number, and locationID.
static void dumpPorts(const char *cls) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(cls), &iter) != KERN_SUCCESS) {
        printf("  (%s: match failed)\n", cls);
        return;
    }
    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(s, name);
        long long portNum = readPortNumber(s, CFSTR("usb-c-port-number"));
        long long loc = readNumber(s, CFSTR("locationID"));
        printf("  %-24s usb-c-port-number=%lld  locationID=%lld (0x%llx)\n",
               name, portNum, loc, (unsigned long long)loc);
        n++;
        IOObjectRelease(s);
    }
    if (n == 0) printf("  (%s: none)\n", cls);
    IOObjectRelease(iter);
}

int main(void) {
    printf("=== USB host-controller port -> physical USB-C port map ===\n");
    printf("device locationID -> XHCI port locationID (solid). usb-c-port-number may differ from HPM @N (probe 35); compare, do not assume equal.\n\n");

    printf("AppleUSB30XHCIARMPort (USB3 / SuperSpeed):\n");
    dumpPorts("AppleUSB30XHCIARMPort");
    printf("\nAppleUSB20XHCIARMPort (USB2):\n");
    dumpPorts("AppleUSB20XHCIARMPort");

    // Connected devices, so the bridge can be checked end to end from this one
    // probe: match a device's locationID base to a port above.
    printf("\nIOUSBHostDevice (connected devices, match locationID to a port above):\n");
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS) {
        io_service_t s;
        int n = 0;
        while ((s = IOIteratorNext(iter))) {
            long long loc = readNumber(s, CFSTR("locationID"));
            char product[256];
            if (!readString(s, CFSTR("USB Product Name"), product, sizeof(product)) || !product[0]) {
                io_name_t nm = {0};
                IORegistryEntryGetName(s, nm);
                snprintf(product, sizeof(product), "%s", nm);
            }
            printf("  locationID=%lld (0x%llx)  %s\n", loc, (unsigned long long)loc, product);
            n++;
            IOObjectRelease(s);
        }
        if (n == 0) printf("  (none connected)\n");
        IOObjectRelease(iter);
    }
    return 0;
}
