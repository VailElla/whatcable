// Deep dive into AppleHPM - walk the full parent/child tree,
// look for any hidden properties, user client classes, or
// notification ports we can register on.
// Compile: clang -framework IOKit -framework CoreFoundation -o hpm_deep_dive 03_hpm_deep_dive.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static void printDataHex(CFDataRef data) {
    CFIndex len = CFDataGetLength(data);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    for (CFIndex i = 0; i < len && i < 128; i++) {
        if (i > 0 && i % 16 == 0) printf("\n        ");
        printf("%02x ", bytes[i]);
    }
    if (len > 128) printf("... (%ld total)", len);
    printf("\n");
}

static void walkTree(io_service_t service, int depth, const char *plane) {
    if (depth > 8) return;

    io_name_t className = {0}, name = {0};
    IOObjectGetClass(service, className);
    IORegistryEntryGetName(service, name);

    for (int i = 0; i < depth; i++) printf("  ");
    printf("[%s] %s", className, name);

    // Check for "UserClientClass" property - tells us what user client exists
    CFTypeRef ucClass = IORegistryEntryCreateCFProperty(
        service, CFSTR("IOUserClientClass"), kCFAllocatorDefault, 0);
    if (ucClass) {
        char buf[256];
        buf[0] = '\0';
        if (CFStringGetCString(ucClass, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf(" (UserClient: %s)", buf);
        } else {
            printf(" (UserClient: <unconvertible>)");
        }
        CFRelease(ucClass);
    }

    // Check for bundle ID
    CFTypeRef bundleID = IORegistryEntryCreateCFProperty(
        service, CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0);
    if (bundleID) {
        char buf[256];
        buf[0] = '\0';
        if (CFStringGetCString(bundleID, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf(" [%s]", buf);
        } else {
            printf(" [<unconvertible>]");
        }
        CFRelease(bundleID);
    }

    printf("\n");

    // Look for interesting VDM/PD-related properties
    const char *interesting[] = {
        "VDMs", "VDOs", "Metadata", "PDRevision", "SpecRevision",
        "PortPartnerIdentity", "CableIdentity", "PDContract",
        "PowerRole", "DataRole", "VCONNSource",
        "SourceCapabilities", "SinkCapabilities",
        "RequestDataObject", "ActiveContract",
        "AlternateMode", "SVIDs", "Modes",
        "DisplayPortStatus", "DisplayPortConfig",
        "RawVDM", "VDMResponse", "VDMHistory",
        "MessageLog", "PDMessageLog", "TraceBuffer",
        NULL
    };

    for (int i = 0; interesting[i]; i++) {
        CFStringRef key = CFStringCreateWithCString(
            kCFAllocatorDefault, interesting[i], kCFStringEncodingUTF8);
        CFTypeRef val = IORegistryEntryCreateCFProperty(
            service, key, kCFAllocatorDefault, 0);
        if (val) {
            for (int j = 0; j < depth + 1; j++) printf("  ");
            printf(">>> %s: ", interesting[i]);

            CFTypeID tid = CFGetTypeID(val);
            if (tid == CFDataGetTypeID()) {
                printf("<data %ld bytes> ", CFDataGetLength(val));
                printDataHex(val);
            } else if (tid == CFNumberGetTypeID()) {
                long long num;
                CFNumberGetValue(val, kCFNumberLongLongType, &num);
                printf("%lld (0x%llx)\n", num, num);
            } else if (tid == CFStringGetTypeID()) {
                char buf[512];
                buf[0] = '\0';
                if (CFStringGetCString(val, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    printf("\"%s\"\n", buf);
                } else {
                    printf("<unconvertible string>\n");
                }
            } else if (tid == CFDictionaryGetTypeID()) {
                printf("<dict with %ld keys>\n", CFDictionaryGetCount(val));
            } else if (tid == CFArrayGetTypeID()) {
                printf("<array with %ld items>\n", CFArrayGetCount(val));
            } else {
                printf("<type %lu>\n", CFGetTypeID(val));
            }
            CFRelease(val);
        }
        CFRelease(key);
    }

    // Recurse into children
    io_iterator_t childIter;
    kern_return_t kr = IORegistryEntryGetChildIterator(service, plane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(childIter))) {
            walkTree(child, depth + 1, plane);
            IOObjectRelease(child);
        }
        IOObjectRelease(childIter);
    }
}

int main(void) {
    printf("=== Walking from AppleHPMARMSPMI in IOService plane ===\n\n");

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMARMSPMI"),
        &iter
    );

    if (kr == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iter))) {
            walkTree(service, 0, kIOServicePlane);
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    } else {
        printf("No AppleHPMARMSPMI found\n");
    }

    // Also try IOPower plane - might show different hierarchy
    printf("\n\n=== Walking AppleHPMARMSPMI in IOPower plane ===\n\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMARMSPMI"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iter))) {
            walkTree(service, 0, "IOPower");
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }

    // Check for any notification-related properties on the PD services
    printf("\n\n=== Checking IOPortTransportComponentCCUSBPDSOPp notification support ===\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOPortTransportComponentCCUSBPDSOPp"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(iter))) {
            // Try to register for interest notifications
            IONotificationPortRef notifyPort = IONotificationPortCreate(kIOMainPortDefault);
            if (notifyPort) {
                io_object_t notifier;
                kr = IOServiceAddInterestNotification(
                    notifyPort, service,
                    kIOGeneralInterest,
                    NULL, NULL, &notifier
                );
                printf("  General interest notification: kr=0x%x %s\n",
                    kr, kr == KERN_SUCCESS ? "SUCCESS" : "FAILED");
                if (kr == KERN_SUCCESS) IOObjectRelease(notifier);

                kr = IOServiceAddInterestNotification(
                    notifyPort, service,
                    kIOBusyInterest,
                    NULL, NULL, &notifier
                );
                printf("  Busy interest notification: kr=0x%x %s\n",
                    kr, kr == KERN_SUCCESS ? "SUCCESS" : "FAILED");
                if (kr == KERN_SUCCESS) IOObjectRelease(notifier);

                IONotificationPortDestroy(notifyPort);
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }

    return 0;
}
