#ifndef BATTERY_H
#define BATTERY_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    int percentage;
    int maxCapacity;
    int designCapacity;
    int fullChargeCapacity;
    int remainingCapacity;
    int avgTimeToEmpty;
    int cycleCount;
    int amperage;       // in mA (positive = charging, negative = discharging, 0 = idle/bypass)
    int voltage;        // in mV
    double wattage;     // in Watts (calculated)
    double temperature; // in Celsius
    bool acAttached;
    bool isCharging;
    bool fullyCharged;
    uint32_t notChargingReason;
    int pmuConfigured;
    int adapterWatts;
    int adapterVoltage_mV;
    int adapterCurrent_mA;
    int adapterSelectedPdo;
    int adapterPdoCount;
    char adapterDesc[64];
    char health[32];
    char serial[32];
    char deviceName[32];
} BatteryInfo;

// Battery Telemetry
bool battery_get_info(BatteryInfo *info);
int battery_get_adapter_watts(void);
const char* battery_get_not_charging_reason_desc(uint32_t reason);

#endif // BATTERY_H
