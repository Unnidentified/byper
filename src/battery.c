#include "battery.h"
#include "smc.h"
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

static int get_dict_int(CFDictionaryRef dict, CFStringRef key, int defaultVal) {
    if (!dict) return defaultVal;
    CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(dict, key);
    if (!num || CFGetTypeID(num) != CFNumberGetTypeID()) return defaultVal;
    int val = defaultVal;
    CFNumberGetValue(num, kCFNumberIntType, &val);
    return val;
}

static bool get_dict_bool(CFDictionaryRef dict, CFStringRef key, bool defaultVal) {
    if (!dict) return defaultVal;
    CFBooleanRef b = (CFBooleanRef)CFDictionaryGetValue(dict, key);
    if (!b || CFGetTypeID(b) != CFBooleanGetTypeID()) return defaultVal;
    return CFBooleanGetValue(b);
}

static void get_dict_string(CFDictionaryRef dict, CFStringRef key, char *buf, size_t maxLen) {
    if (!dict || !buf || maxLen == 0) return;
    CFStringRef str = (CFStringRef)CFDictionaryGetValue(dict, key);
    if (!str || CFGetTypeID(str) != CFStringGetTypeID()) return;
    CFStringGetCString(str, buf, maxLen, kCFStringEncodingUTF8);
}

bool battery_get_info(BatteryInfo *info) {
    if (!info) return false;
    memset(info, 0, sizeof(BatteryInfo));

    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator) != kIOReturnSuccess) {
        return false;
    }
    io_object_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!service) return false;

    CFMutableDictionaryRef propDict = NULL;
    if (IORegistryEntryCreateCFProperties(service, &propDict, kCFAllocatorDefault, 0) != kIOReturnSuccess || !propDict) {
        IOObjectRelease(service);
        return false;
    }
    IOObjectRelease(service);

    // Extract battery data
    info->percentage = get_dict_int(propDict, CFSTR("CurrentCapacity"), 0);
    info->maxCapacity = get_dict_int(propDict, CFSTR("MaxCapacity"), 100);
    info->designCapacity = get_dict_int(propDict, CFSTR("DesignCapacity"), 0);
    info->cycleCount = get_dict_int(propDict, CFSTR("CycleCount"), 0);
    info->amperage = get_dict_int(propDict, CFSTR("Amperage"), 0);
    if (info->amperage == 0) {
        info->amperage = get_dict_int(propDict, CFSTR("InstantAmperage"), 0);
    }
    info->voltage = get_dict_int(propDict, CFSTR("AppleRawBatteryVoltage"), 0);
    if (info->voltage == 0) {
        info->voltage = get_dict_int(propDict, CFSTR("Voltage"), 0);
    }

    bool isChargingFromDict = get_dict_bool(propDict, CFSTR("IsCharging"), false);
    info->fullyCharged = get_dict_bool(propDict, CFSTR("FullyCharged"), false);
    info->acAttached = get_dict_bool(propDict, CFSTR("ExternalConnected"), false);

    // ChargerData
    int isChargingCD = 0;
    CFDictionaryRef chargerData = (CFDictionaryRef)CFDictionaryGetValue(propDict, CFSTR("ChargerData"));
    if (chargerData && CFGetTypeID(chargerData) == CFDictionaryGetTypeID()) {
        info->notChargingReason = (uint32_t)get_dict_int(chargerData, CFSTR("NotChargingReason"), 0);
        info->pmuConfigured = get_dict_int(chargerData, CFSTR("PMUConfigured"), 0);
        isChargingCD = get_dict_int(chargerData, CFSTR("IsCharging"), 0);
    }

    // Unbuffered live hardware ammeter from AppleSMC (B0AC)
    io_iterator_t smcIter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &smcIter) == kIOReturnSuccess) {
        io_object_t smcService = IOIteratorNext(smcIter);
        IOObjectRelease(smcIter);
        if (smcService) {
            io_connect_t conn = 0;
            if (IOServiceOpen(smcService, mach_task_self(), 0, &conn) == kIOReturnSuccess && conn) {
                struct {
                    uint32_t key;
                    uint8_t vers;
                    uint8_t pLimitData;
                    uint16_t data8;
                    uint32_t data32;
                    uint8_t bytes[32];
                } inputStruct, outputStruct;
                memset(&inputStruct, 0, sizeof(inputStruct));
                memset(&outputStruct, 0, sizeof(outputStruct));
                size_t structSize = sizeof(outputStruct);
                inputStruct.key = ('B' << 24) | ('0' << 16) | ('A' << 8) | 'C';
                inputStruct.vers = 5; // kSMCReadKey
                if (IOConnectCallStructMethod(conn, 2, &inputStruct, sizeof(inputStruct), &outputStruct, &structSize) == kIOReturnSuccess) {
                    int16_t smcAmps = (int16_t)((outputStruct.bytes[0] << 8) | outputStruct.bytes[1]);
                    info->amperage = smcAmps;
                }
                IOServiceClose(conn);
            }
            IOObjectRelease(smcService);
        }
    }

    // Accurate charging state:
    // If hold is engaged (notChargingReason == 0x01000000 or amperage <= 0 with AC connected), isCharging is false.
    // If NotChargingReason == 0 && amperage > 0 && PMUConfigured > 0, isCharging is true.
    if ((info->notChargingReason & 0x01000000) != 0 || isChargingCD == 0 || !isChargingFromDict || info->amperage <= 0) {
        info->isCharging = false;
    } else if (info->notChargingReason == 0 && (info->pmuConfigured > 0 || isChargingCD == 1 || isChargingFromDict) && info->amperage > 0) {
        info->isCharging = true;
    } else {
        info->isCharging = isChargingFromDict;
    }

    info->wattage = ((double)info->amperage * (double)info->voltage) / 1000000.0;
    if (info->wattage < 0) info->wattage = -info->wattage; // absolute wattage magnitude

    // BatteryData
    CFDictionaryRef batteryData = (CFDictionaryRef)CFDictionaryGetValue(propDict, CFSTR("BatteryData"));
    if (batteryData && CFGetTypeID(batteryData) == CFDictionaryGetTypeID()) {
        int tempRaw = get_dict_int(batteryData, CFSTR("Temperature"), 0);
        if (tempRaw > 0) {
            info->temperature = ((double)tempRaw / 100.0) - 273.15;
            if (info->temperature < 0 || info->temperature > 100) {
                info->temperature = (double)tempRaw / 10.0;
            }
        }
        if (info->designCapacity == 0) {
            info->designCapacity = get_dict_int(batteryData, CFSTR("DesignCapacity"), 0);
        }
        info->fullChargeCapacity = get_dict_int(batteryData, CFSTR("FullChargeCapacity"), 0);
        info->remainingCapacity = get_dict_int(batteryData, CFSTR("RemainingCapacity"), 0);
        info->avgTimeToEmpty = get_dict_int(batteryData, CFSTR("AvgTimeToEmpty"), 0);
    }

    if (info->temperature <= 0.0) {
        io_connect_t sConn = smc_open();
        if (sConn) {
            uint8_t tbuf[32] = {0};
            uint32_t tsz = 0;
            char ttype[5] = {0};
            if (smc_read_bytes(sConn, "TB0T", tbuf, &tsz, ttype) && tsz == 4) {
                float ftemp = *(float *)tbuf;
                if (ftemp > 0.0f && ftemp < 100.0f) {
                    info->temperature = (double)ftemp;
                }
            }
            smc_close(sConn);
        }
    }

    // Strings
    get_dict_string(propDict, CFSTR("Serial"), info->serial, sizeof(info->serial));
    get_dict_string(propDict, CFSTR("DeviceName"), info->deviceName, sizeof(info->deviceName));

    // Fallback to IOPS if needed for AC attached state
    CFTypeRef psInfo = IOPSCopyPowerSourcesInfo();
    if (psInfo) {
        CFArrayRef psList = IOPSCopyPowerSourcesList(psInfo);
        if (psList) {
            if (CFArrayGetCount(psList) > 0) {
                CFTypeRef psDesc = IOPSGetPowerSourceDescription(psInfo, CFArrayGetValueAtIndex(psList, 0));
                if (psDesc) {
                    CFStringRef psState = (CFStringRef)CFDictionaryGetValue((CFDictionaryRef)psDesc, CFSTR(kIOPSPowerSourceStateKey));
                    if (psState && CFStringCompare(psState, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) {
                        info->acAttached = true;
                    }
                    if (info->percentage == 0) {
                        info->percentage = get_dict_int((CFDictionaryRef)psDesc, CFSTR(kIOPSCurrentCapacityKey), 0);
                    }
                    if (info->avgTimeToEmpty == 0) {
                        info->avgTimeToEmpty = get_dict_int((CFDictionaryRef)psDesc, CFSTR(kIOPSTimeToEmptyKey), 0);
                    }
                }
            }
            CFRelease(psList);
        }
        CFRelease(psInfo);
    }

    // Adapter & USB-PD PDO Details
    CFDictionaryRef details = IOPSCopyExternalPowerAdapterDetails();
    if (details) {
        info->adapterWatts = get_dict_int(details, CFSTR(kIOPSPowerAdapterWattsKey), 0);
        info->adapterVoltage_mV = get_dict_int(details, CFSTR("AdapterVoltage"), 0);
        info->adapterCurrent_mA = get_dict_int(details, CFSTR("Current"), 0);
        info->adapterSelectedPdo = get_dict_int(details, CFSTR("UsbHvcHvcIndex"), 0);
        get_dict_string(details, CFSTR("Description"), info->adapterDesc, sizeof(info->adapterDesc));
        
        CFArrayRef menu = (CFArrayRef)CFDictionaryGetValue(details, CFSTR("UsbHvcMenu"));
        if (menu && CFGetTypeID(menu) == CFArrayGetTypeID()) {
            info->adapterPdoCount = (int)CFArrayGetCount(menu);
        }
        CFRelease(details);
    }

    CFRelease(propDict);
    return true;
}

int battery_get_adapter_watts(void) {
    CFDictionaryRef details = IOPSCopyExternalPowerAdapterDetails();
    int watts = 0;
    if (details) {
        CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(details, CFSTR(kIOPSPowerAdapterWattsKey));
        if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
            CFNumberGetValue(num, kCFNumberIntType, &watts);
        }
        CFRelease(details);
    }
    return watts;
}

const char* battery_get_not_charging_reason_desc(uint32_t reason) {
    if (reason == 0) return "Normal / Charging Allowed";
    if (reason == 16777216 || reason == 0x01000000) return "Charging On Hold (AC Bypass Active)";
    if (reason == 4096 || reason == 0x00001000) return "Desktop Mode Budget Limit (Charging Active)";
    if (reason & 0x01000000) return "Charging On Hold (AC Bypass Active)";
    if (reason & 0x00001000) return "Desktop Mode Budget Limit (Charging Active)";
    if (reason & 0x00000001) return "Thermal Throttle (Too Hot)";
    if (reason & 0x00000002) return "Low Power Input";
    if (reason & 0x00000004) return "Battery Fully Charged";
    if (reason & 0x00000008) return "Incompatible Adapter";
    return "Power Management Hold";
}
