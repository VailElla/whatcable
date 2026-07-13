// Dump EVERY property from every IOPort* and AppleHPM* service.
// No filtering - we want to see everything the kernel exposes,
// including anything undocumented.
// Compile: clang -framework IOKit -framework CoreFoundation -o raw_registry_dump 04_raw_registry_dump.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

static void dumpValue(CFTypeRef value, int indent);

static void dumpDict(CFDictionaryRef dict, int indent) {
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        for (int j = 0; j < indent; j++) printf("  ");
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(keys[i], buf, sizeof(buf), kCFStringEncodingUTF8)) {
                printf("\"%s\": ", buf);
            } else {
                printf("<unconvertible-key>: ");
            }
        } else {
            printf("<key>: ");
        }
        dumpValue(vals[i], indent + 1);
    }
    free(keys);
    free(vals);
}

static void dumpValue(CFTypeRef value, int indent) {
    if (!value) { printf("null\n"); return; }
    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[2048];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf("\"%s\"\n", buf);
        } else {
            printf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        long long n;
        CFNumberGetValue(value, kCFNumberLongLongType, &n);
        printf("%lld (0x%llx)\n", n, n);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        printf("<data %ld>: ", len);
        for (CFIndex i = 0; i < len; i++) {
            printf("%02x", b[i]);
            if (i < len - 1 && (i + 1) % 4 == 0) printf(" ");
        }
        printf("\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            for (int j = 0; j < indent; j++) printf("  ");
            printf("[%ld] ", i);
            dumpValue(CFArrayGetValueAtIndex(value, i), indent + 1);
        }
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        dumpDict(value, indent);
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("}\n");
    } else {
        printf("<type-%lu>\n", tid);
    }
}

static void dumpAllMatchingServices(const char *className) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(className),
        &iter
    );
    if (kr != KERN_SUCCESS) return;

    io_service_t service;
    int idx = 0;
    while ((service = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(service, name);

        printf("\n========================================\n");
        printf("%s[%d] (name: %s)\n", className, idx++, name);
        printf("========================================\n");

        CFMutableDictionaryRef props = NULL;
        kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
        if (kr == KERN_SUCCESS && props) {
            dumpDict(props, 1);
            CFRelease(props);
        }

        // Also check parent classes
        // Walk up the class hierarchy
        io_name_t curClass = {0};
        IOObjectGetClass(service, curClass);
        printf("  Class hierarchy: %s", curClass);

        // Check if it conforms to known base classes
        const char *bases[] = {
            "IOService", "IORegistryEntry", "IOUserClient",
            "IOPort", "IOPortFeature", "IOPortTransportComponent",
            "IOAccessoryManager", NULL
        };
        for (int i = 0; bases[i]; i++) {
            if (IOObjectConformsTo(service, bases[i])) {
                printf(" -> %s", bases[i]);
            }
        }
        printf("\n");

        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
}

int main(void) {
    // Cast a wide net - search for every class prefix that might be relevant
    const char *prefixes[] = {
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
        "IOPortTransportStateCC",
        "IOPortFeaturePowerIn",
        "IOPortFeatureLDCM",
        "IOPortFeatureUSBCOvercurrent",
        "AppleHPMInterfaceType",
        "AppleHPMARMSPMI",
        "AppleHPMLDCMType",
        "AppleTypeCPort",
        "AppleT8132TypeCPhy",
        "AppleTypeCRetimer",
        "IOAccessoryManager",
        "IOAccessoryPort",
        "AppleUSBCPort",
        "IOUSBHostDevice",
        "AppleUSBVHCIPort",
        "IOThunderboltPort",
        NULL
    };

    for (int i = 0; prefixes[i]; i++) {
        dumpAllMatchingServices(prefixes[i]);
    }

    return 0;
}
