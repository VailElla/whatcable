// Map each USB-C port (Port-USB-C@N) to its power-controller UUID.
//
// Why this exists: on desktop Macs the per-port power-out readings live in the
// SMC (probe 34: DxJV volts, DxJI amps, DxUI a UUID per channel). But the SMC
// channel numbers (D1..D4) do NOT line up with the physical port numbers
// (Port-USB-C@N). The missing link is this: each port's power controller
// (AppleHPMDeviceHALType3) carries a UUID, and that same UUID is the SMC
// channel's DxUI. So:
//
//     Port-USB-C@N  <-  AppleHPMDeviceHALType3.UUID  ==  SMC DxUI  ->  watts
//
// Matching the two UUIDs ties a power channel to the right physical port with
// no guessing. This probe captures the port half of that join (the @N and its
// UUID); probe 34 captures the SMC half.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 35_hpm_port_uuid 35_hpm_port_uuid.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// Copy a CFString property into buf. Returns 1 on success, 0 otherwise.
static int readStringProp(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Read a CFNumber property as long long. Returns 1 on success.
static int readNumberProp(io_service_t s, CFStringRef key, long long *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue(v, kCFNumberLongLongType, out);
    }
    if (v) CFRelease(v);
    return ok;
}

// Walk descendants looking for a "Description" property that contains "@",
// e.g. "Port-USB-C@1/CC". Used as a fallback when the port node's location
// in the IOService plane is empty. Returns 1 if found.
static int findDescriptionWithLocation(io_service_t service, int depth, char *out, size_t n) {
    if (depth > 4) return 0;

    char desc[256];
    if (readStringProp(service, CFSTR("Description"), desc, sizeof(desc))) {
        if (strchr(desc, '@') != NULL) {
            // Trim at the first '/' so we keep just "Port-USB-C@N".
            char *slash = strchr(desc, '/');
            if (slash) *slash = '\0';
            snprintf(out, n, "%s", desc);
            return 1;
        }
    }

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS) {
        io_service_t child;
        int found = 0;
        while ((child = IOIteratorNext(childIter))) {
            if (!found && findDescriptionWithLocation(child, depth + 1, out, n)) {
                found = 1;
            }
            IOObjectRelease(child);
        }
        IOObjectRelease(childIter);
        if (found) return 1;
    }
    return 0;
}

// Find the Port-USB-C@N label for a power-controller node by inspecting its
// child port. Tries the registry location first, then a Description fallback.
static void resolvePortLabel(io_service_t hpm, char *out, size_t n) {
    snprintf(out, n, "(no port child)");

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(hpm, kIOServicePlane, &childIter) != KERN_SUCCESS) {
        return;
    }

    io_service_t child;
    while ((child = IOIteratorNext(childIter))) {
        io_name_t name = {0};
        if (IORegistryEntryGetName(child, name) != KERN_SUCCESS) {
            IOObjectRelease(child);
            continue;
        }
        if (strstr(name, "Port-USB-C") != NULL) {
            io_name_t loc = {0};
            IORegistryEntryGetLocationInPlane(child, kIOServicePlane, loc);
            if (loc[0] != '\0') {
                snprintf(out, n, "%s@%s", name, loc);
            } else if (!findDescriptionWithLocation(child, 0, out, n)) {
                snprintf(out, n, "%s", name);
            }
            IOObjectRelease(child);
            IOObjectRelease(childIter);
            return;
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(childIter);
}

int main(void) {
    printf("=== Port-USB-C@N -> power-controller UUID map ===\n");
    printf("Join key: this UUID == SMC DxUI (probe 34). Match to tie a port to its power channel.\n\n");

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMDeviceHALType3"),
        &iter);
    if (kr != KERN_SUCCESS) {
        printf("No AppleHPMDeviceHALType3 found (kr=0x%x)\n", kr);
        return 0;
    }

    io_service_t hpm;
    int idx = 0;
    while ((hpm = IOIteratorNext(iter))) {
        char uuid[128] = "(none)";
        readStringProp(hpm, CFSTR("UUID"), uuid, sizeof(uuid));

        long long rid = -1, addr = -1;
        readNumberProp(hpm, CFSTR("RID"), &rid);
        readNumberProp(hpm, CFSTR("Address"), &addr);

        char portLabel[160];
        resolvePortLabel(hpm, portLabel, sizeof(portLabel));

        printf("[%d] %-20s  UUID=%s  RID=%lld  Address=%lld\n",
               idx, portLabel, uuid, rid, addr);

        idx++;
        IOObjectRelease(hpm);
    }
    IOObjectRelease(iter);

    if (idx == 0) printf("(no power controllers matched)\n");
    return 0;
}
