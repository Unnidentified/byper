#include "power.h"
#include "powerui.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <math.h>


static float read_smc_float(io_connect_t conn, const char *key) {
    if (!conn) return 0.0f;
    uint8_t buf[4] = {0};
    uint32_t sz = 0;
    if (smc_read_bytes(conn, key, buf, &sz, NULL)) {
        float f = 0.0f;
        memcpy(&f, buf, 4);
        return f;
    }
    return 0.0f;
}

bool power_sample_breakdown(PowerBreakdown *pb) {
    if (!pb) return false;
    memset(pb, 0, sizeof(PowerBreakdown));

    BatteryInfo bInfo;
    if (!battery_get_info(&bInfo)) return false;

    pb->percentage = bInfo.percentage;
    pb->ac_connected = bInfo.acAttached;
    pb->is_charging = bInfo.isCharging;
    pb->battery_ma = bInfo.amperage;
    pb->battery_mv = bInfo.voltage;
    pb->not_charging_reason = bInfo.notChargingReason;

    pb->is_hold = (pb->ac_connected && !pb->is_charging && ((pb->not_charging_reason & 0x01000000) != 0) && abs(pb->battery_ma) < 100);

    io_connect_t conn = smc_open();
    if (conn) {
        pb->soc_w = read_smc_float(conn, "PDBR");
        pb->dram_w = read_smc_float(conn, "PMVR");
        pb->pmic_w = read_smc_float(conn, "PMVC");
        pb->pkg_w = read_smc_float(conn, "PPMC");
        pb->hi_pwr_w = read_smc_float(conn, "PHPM");
        pb->dc_in_w = read_smc_float(conn, "PDTR");

        uint8_t buf[2];
        uint32_t sz;
        if (smc_read_bytes(conn, "BC1V", buf, &sz, NULL)) pb->cell1_mv = (buf[1] << 8) | buf[0];
        if (smc_read_bytes(conn, "BC2V", buf, &sz, NULL)) pb->cell2_mv = (buf[1] << 8) | buf[0];
        if (smc_read_bytes(conn, "BC3V", buf, &sz, NULL)) pb->cell3_mv = (buf[1] << 8) | buf[0];

        smc_close(conn);
    }

    // ADDENDUM 3: Power Flow Math (Single Source of Truth)
    // battery_W = (V_batt * A_batt) / 1000000.0 (signed)
    // wall_W = DC-in (from PDTR / adapter)
    // load_W = wall_W - battery_W on AC (clamped to >= 0)
    // load_W = -battery_W when unplugged (on battery)
    // The laptop line MUST print load_W (derived system load), NEVER raw DC-in when charging!
    double battery_w_signed = ((double)pb->battery_mv * (double)pb->battery_ma) / 1000000.0;
    pb->battery_w = battery_w_signed;

    double wall_w = 0.0;
    if (pb->ac_connected) {
        if (pb->dc_in_w > 0.0f) {
            wall_w = (double)pb->dc_in_w;
        } else {
            int ad_w = battery_get_adapter_watts();
            if (ad_w > 0) {
                wall_w = (double)ad_w;
            } else {
                wall_w = (double)(pb->soc_w + pb->dram_w + pb->pmic_w + pb->pkg_w + 1.2f) + (pb->is_charging ? battery_w_signed : 0.0);
            }
        }
        double load_w = wall_w - battery_w_signed;
        if (load_w < 0.0) load_w = 0.0;
        pb->total_system_w = load_w;
    } else {
        double load_w = -battery_w_signed;
        if (load_w < 0.0) load_w = 0.0;
        pb->total_system_w = load_w;
    }

    return true;
}
