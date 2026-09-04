#ifndef POWER_H
#define POWER_H

#include <stdint.h>
#include <stdbool.h>
#include "smc.h"
#include "battery.h"

typedef struct {
    float soc_w;
    float dram_w;
    float pmic_w;
    float pkg_w;
    float hi_pwr_w;
    float dc_in_w;
    uint16_t cell1_mv;
    uint16_t cell2_mv;
    uint16_t cell3_mv;
    double total_system_w;
    double battery_w;
    int battery_ma;
    int battery_mv;
    int percentage;
    bool ac_connected;
    bool is_charging;
    bool is_hold;
    uint32_t not_charging_reason;
} PowerBreakdown;

// Core functions
bool power_sample_breakdown(PowerBreakdown *pb);

#endif // POWER_H
