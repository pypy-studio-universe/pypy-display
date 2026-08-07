// DDC transport design adapted from m1ddc by waydabber (MIT License).
// See THIRD_PARTY_NOTICES.md for the copyright notice and license.

#include "DisplayDDC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

typedef CFTypeRef IOAVServiceRef;
typedef CFDictionaryRef (*CoreDisplayCreateInfoFunction)(CGDirectDisplayID);

extern IOAVServiceRef IOAVServiceCreateWithService(
    CFAllocatorRef allocator,
    io_service_t service
);
extern IOReturn IOAVServiceReadI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t offset,
    void *outputBuffer,
    uint32_t outputBufferSize
);
extern IOReturn IOAVServiceWriteI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    void *inputBuffer,
    uint32_t inputBufferSize
);

typedef struct {
    IOAVServiceRef service;
    uint32_t chipAddress;
} PypyDDCTransport;

static const uint32_t kPypyDefaultChipAddress = 0x37;
static const uint32_t kPypyMCDP29xxChipAddress = 0xB7;
static const uint32_t kPypyInputAddress = 0x51;
static const uint8_t kPypyLuminanceVCPCode = 0x10;

static CoreDisplayCreateInfoFunction PypyCoreDisplayCreateInfo(void) {
    static CoreDisplayCreateInfoFunction function = NULL;
    static bool initialized = false;
    if (!initialized) {
        initialized = true;
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (handle != NULL) {
            function = (CoreDisplayCreateInfoFunction)dlsym(
                handle,
                "CoreDisplay_DisplayCreateInfoDictionary"
            );
        }
    }
    return function;
}

static CFTypeRef PypyCopyRecursiveProperty(
    io_registry_entry_t service,
    CFStringRef key
) {
    return IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
}

static bool PypyIsMCDP29xxProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) {
        return false;
    }

    bool result = false;
    CFTypeRef providerClass = IORegistryEntryCreateCFProperty(
        parent,
        CFSTR("EPICProviderClass"),
        kCFAllocatorDefault,
        0
    );
    if (providerClass != NULL && CFGetTypeID(providerClass) == CFStringGetTypeID()) {
        result = CFStringCompare(
            providerClass,
            CFSTR("AppleDCPMCDP29XX"),
            0
        ) == kCFCompareEqualTo;
    }
    if (providerClass != NULL) {
        CFRelease(providerClass);
    }
    IOObjectRelease(parent);
    return result;
}

static PypyDDCTransport PypyTransportForDisplay(CGDirectDisplayID displayID) {
    PypyDDCTransport transport = { NULL, kPypyDefaultChipAddress };
    CoreDisplayCreateInfoFunction createInfo = PypyCoreDisplayCreateInfo();
    if (createInfo == NULL) {
        return transport;
    }

    CFDictionaryRef displayInfo = createInfo(displayID);
    if (displayInfo == NULL) {
        return transport;
    }

    CFStringRef ioLocation = CFDictionaryGetValue(
        displayInfo,
        CFSTR("IODisplayLocation")
    );
    if (ioLocation == NULL || CFGetTypeID(ioLocation) != CFStringGetTypeID()) {
        CFRelease(displayInfo);
        return transport;
    }

    io_registry_entry_t adapter = IORegistryEntryCopyFromPath(
        kIOMainPortDefault,
        ioLocation
    );
    if (adapter == MACH_PORT_NULL) {
        CFRelease(displayInfo);
        return transport;
    }

    uint64_t adapterID = 0;
    if (IORegistryEntryGetRegistryEntryID(adapter, &adapterID) != KERN_SUCCESS) {
        IOObjectRelease(adapter);
        CFRelease(displayInfo);
        return transport;
    }

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iterator = MACH_PORT_NULL;
    kern_return_t iteratorResult = IORegistryEntryCreateIterator(
        root,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        &iterator
    );
    IOObjectRelease(root);
    if (iteratorResult != KERN_SUCCESS) {
        IOObjectRelease(adapter);
        CFRelease(displayInfo);
        return transport;
    }

    bool matchingFramebuffer = false;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (IOObjectConformsTo(service, "IOMobileFramebuffer")) {
            uint64_t framebufferID = 0;
            matchingFramebuffer =
                IORegistryEntryGetRegistryEntryID(service, &framebufferID) == KERN_SUCCESS &&
                framebufferID == adapterID;
            IOObjectRelease(service);
            continue;
        }

        io_name_t serviceName = { 0 };
        IORegistryEntryGetName(service, serviceName);
        if (!matchingFramebuffer || strcmp(serviceName, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(service);
            continue;
        }

        CFTypeRef location = PypyCopyRecursiveProperty(service, CFSTR("Location"));
        bool isExternal =
            location != NULL &&
            CFGetTypeID(location) == CFStringGetTypeID() &&
            CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location != NULL) {
            CFRelease(location);
        }
        if (!isExternal) {
            IOObjectRelease(service);
            continue;
        }

        transport.service = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
        if (transport.service != NULL && PypyIsMCDP29xxProxy(service)) {
            transport.chipAddress = kPypyMCDP29xxChipAddress;
        }
        IOObjectRelease(service);
        break;
    }

    IOObjectRelease(iterator);
    IOObjectRelease(adapter);
    CFRelease(displayInfo);
    return transport;
}

static IOReturn PypyWritePacket(
    PypyDDCTransport transport,
    uint8_t *data,
    uint32_t length
) {
    IOReturn result = kIOReturnError;
    for (int attempt = 0; attempt < 2; attempt++) {
        usleep(10000);
        result = IOAVServiceWriteI2C(
            transport.service,
            transport.chipAddress,
            kPypyInputAddress,
            data,
            length
        );
        if (result == kIOReturnSuccess) {
            break;
        }
    }
    return result;
}

bool PypyDDCReadBrightness(
    CGDirectDisplayID displayID,
    uint16_t *currentValue,
    uint16_t *maximumValue
) {
    if (currentValue == NULL || maximumValue == NULL) {
        return false;
    }

    PypyDDCTransport transport = PypyTransportForDisplay(displayID);
    if (transport.service == NULL) {
        return false;
    }

    uint8_t request[4] = { 0x82, 0x01, kPypyLuminanceVCPCode, 0x00 };
    request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2];
    IOReturn writeResult = PypyWritePacket(transport, request, 4);
    if (writeResult != kIOReturnSuccess) {
        CFRelease(transport.service);
        return false;
    }

    usleep(transport.chipAddress == kPypyMCDP29xxChipAddress ? 50000 : 10000);
    uint8_t response[12] = { 0 };
    IOReturn readResult = IOAVServiceReadI2C(
        transport.service,
        transport.chipAddress,
        kPypyInputAddress,
        response,
        sizeof(response)
    );
    CFRelease(transport.service);
    if (readResult != kIOReturnSuccess) {
        return false;
    }

    uint16_t maximum = ((uint16_t)response[6] << 8) | response[7];
    uint16_t current = ((uint16_t)response[8] << 8) | response[9];
    if (maximum == 0 || current > maximum) {
        return false;
    }

    *currentValue = current;
    *maximumValue = maximum;
    return true;
}

bool PypyDDCSetBrightness(CGDirectDisplayID displayID, uint16_t value) {
    PypyDDCTransport transport = PypyTransportForDisplay(displayID);
    if (transport.service == NULL) {
        return false;
    }

    uint8_t data[6] = {
        0x84,
        0x03,
        kPypyLuminanceVCPCode,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFF),
        0x00
    };
    data[5] = 0x6E ^ kPypyInputAddress ^ data[0] ^ data[1] ^
        data[2] ^ data[3] ^ data[4];

    IOReturn result = PypyWritePacket(transport, data, sizeof(data));
    CFRelease(transport.service);
    return result == kIOReturnSuccess;
}
