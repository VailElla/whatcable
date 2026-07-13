// Walk the IOKit tree around USB-PD services and dump everything we can see.
// Compile: clang -framework IOKit -framework CoreFoundation -o walk_pd_tree 01_walk_pd_tree.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static void printCFValue(CFTypeRef value, int indent);

static void printCFDict(CFDictionaryRef dict, int indent) {
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        for (int j = 0; j < indent; j++) printf("  ");

        char keyBuf[256] = {0};
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            // Zero the buffer first and check the return: CFStringGetCString
            // can fail (too long, lossy encoding) and leaves buf unspecified
            // on failure, not just untouched.
            if (!CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8))
                snprintf(keyBuf, sizeof(keyBuf), "<unconvertible-key>");
        } else {
            snprintf(keyBuf, sizeof(keyBuf), "<non-string-key>");
        }
        printf("%s = ", keyBuf);
        printCFValue(vals[i], indent + 1);
    }
    free(keys);
    free(vals);
}

static void printCFValue(CFTypeRef value, int indent) {
    if (!value) { printf("(null)\n"); return; }

    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[1024];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf("\"%s\"\n", buf);
        } else {
            printf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        long long num;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%lld (0x%llx)\n", num, num);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("<data %ld bytes:", len);
        for (CFIndex i = 0; i < len && i < 64; i++) {
            printf(" %02x", bytes[i]);
        }
        if (len > 64) printf(" ...");
        printf(">\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            for (int j = 0; j < indent; j++) printf("  ");
            printf("[%ld] ", i);
            printCFValue(CFArrayGetValueAtIndex(value, i), indent + 1);
        }
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        printCFDict(value, indent);
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("}\n");
    } else {
        CFStringRef desc = CFCopyDescription(value);
        char buf[512];
        buf[0] = '\0';
        if (!CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "unconvertible");
        printf("<%s>\n", buf);
        CFRelease(desc);
    }
}

static void dumpService(io_service_t service, const char *label) {
    io_name_t className = {0};
    IOObjectGetClass(service, className);

    io_name_t name = {0};
    IORegistryEntryGetName(service, name);

    printf("\n=== %s ===\n", label);
    printf("  Class: %s\n", className);
    printf("  Name:  %s\n", name);

    // Get ALL properties
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
    if (kr == KERN_SUCCESS && props) {
        printf("  Properties:\n");
        printCFDict(props, 2);
        CFRelease(props);
    } else {
        printf("  (no properties, kr=%d)\n", kr);
    }

    // Walk children in IOService plane
    io_iterator_t childIter;
    kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(childIter))) {
            io_name_t childClass = {0};
            IOObjectGetClass(child, childClass);
            printf("  Child: %s\n", childClass);
            IOObjectRelease(child);
        }
        IOObjectRelease(childIter);
    }
}

int main(void) {
    const char *classes[] = {
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
        "AppleHPMInterfaceType",
        "AppleHPMARMSPMI",
        "IOPortTransportStateCC",
        "IOPortFeaturePowerIn",
        "AppleTypeCPort",
        "AppleT8132TypeCPhy",
        "AppleTypeCRetimer",
        "IOAccessoryManager",
        NULL
    };

    for (int i = 0; classes[i]; i++) {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(classes[i]),
            &iter
        );
        if (kr != KERN_SUCCESS) {
            printf("\n--- %s: no matches (kr=%d) ---\n", classes[i], kr);
            continue;
        }

        io_service_t service;
        int idx = 0;
        while ((service = IOIteratorNext(iter))) {
            char label[256];
            snprintf(label, sizeof(label), "%s[%d]", classes[i], idx++);
            dumpService(service, label);
            IOObjectRelease(service);
        }
        if (idx == 0) {
            printf("\n--- %s: iterator empty ---\n", classes[i]);
        }
        IOObjectRelease(iter);
    }

    return 0;
}
