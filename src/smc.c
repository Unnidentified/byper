#include "smc.h"
#include <stdio.h>
#include <string.h>

uint32_t smc_str_to_key(const char *str) {
    uint32_t total = 0;
    for (int i = 0; i < 4; i++) {
        total = (total << 8) | (uint8_t)str[i];
    }
    return total;
}

void smc_key_to_str(uint32_t key, char *str) {
    str[0] = (key >> 24) & 0xff;
    str[1] = (key >> 16) & 0xff;
    str[2] = (key >> 8) & 0xff;
    str[3] = key & 0xff;
    str[4] = 0;
}

io_connect_t smc_open(void) {
    mach_port_t masterPort = kIOMainPortDefault;
    io_iterator_t iterator;
    CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
    kern_return_t result = IOServiceGetMatchingServices(masterPort, matchingDictionary, &iterator);
    if (result != kIOReturnSuccess) {
        return 0;
    }
    io_object_t device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!device) {
        return 0;
    }
    io_connect_t conn = 0;
    result = IOServiceOpen(device, mach_task_self(), 0, &conn);
    IOObjectRelease(device);
    if (result != kIOReturnSuccess) {
        return 0;
    }
    return conn;
}

void smc_close(io_connect_t conn) {
    if (conn) {
        IOServiceClose(conn);
    }
}

bool smc_get_key_info(io_connect_t conn, const char *key, SMCKeyData_keyInfo_t *info) {
    if (!conn || !key || strlen(key) != 4) return false;

    SMCParamStruct inputStruct;
    SMCParamStruct outputStruct;
    size_t structSize = sizeof(SMCParamStruct);

    memset(&inputStruct, 0, sizeof(SMCParamStruct));
    memset(&outputStruct, 0, sizeof(SMCParamStruct));

    inputStruct.key = smc_str_to_key(key);
    inputStruct.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, structSize, &outputStruct, &structSize);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return false;
    }

    if (info) {
        *info = outputStruct.keyInfo;
    }
    return true;
}

bool smc_read_bytes(io_connect_t conn, const char *key, uint8_t *buffer, uint32_t *size, char *typeOut) {
    if (!conn || !key || !buffer) return false;

    SMCKeyData_keyInfo_t keyInfo;
    if (!smc_get_key_info(conn, key, &keyInfo)) {
        return false;
    }

    if (typeOut) {
        smc_key_to_str(keyInfo.dataType, typeOut);
    }

    SMCParamStruct inputStruct;
    SMCParamStruct outputStruct;
    size_t structSize = sizeof(SMCParamStruct);

    memset(&inputStruct, 0, sizeof(SMCParamStruct));
    memset(&outputStruct, 0, sizeof(SMCParamStruct));

    inputStruct.key = smc_str_to_key(key);
    inputStruct.keyInfo.dataSize = keyInfo.dataSize;
    inputStruct.data8 = SMC_CMD_READ_BYTES;

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, structSize, &outputStruct, &structSize);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return false;
    }

    if (size) {
        *size = keyInfo.dataSize;
    }
    memcpy(buffer, outputStruct.bytes, keyInfo.dataSize);
    return true;
}

bool smc_write_bytes(io_connect_t conn, const char *key, const uint8_t *buffer, uint32_t size) {
    if (!conn || !key || !buffer) return false;

    SMCKeyData_keyInfo_t keyInfo;
    if (!smc_get_key_info(conn, key, &keyInfo)) {
        return false;
    }

    if (size > keyInfo.dataSize) {
        size = keyInfo.dataSize;
    }

    SMCParamStruct inputStruct;
    SMCParamStruct outputStruct;
    size_t structSize = sizeof(SMCParamStruct);

    memset(&inputStruct, 0, sizeof(SMCParamStruct));
    memset(&outputStruct, 0, sizeof(SMCParamStruct));

    inputStruct.key = smc_str_to_key(key);
    inputStruct.keyInfo.dataSize = keyInfo.dataSize;
    inputStruct.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(inputStruct.bytes, buffer, size);

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, structSize, &outputStruct, &structSize);
    if (kr != kIOReturnSuccess || outputStruct.result != 0) {
        return false;
    }

    return true;
}

bool smc_read_ui8(io_connect_t conn, const char *key, uint8_t *val) {
    uint32_t sz = 0;
    return smc_read_bytes(conn, key, val, &sz, NULL);
}

bool smc_read_ui16(io_connect_t conn, const char *key, uint16_t *val) {
    uint8_t buf[2] = {0};
    uint32_t sz = 0;
    if (!smc_read_bytes(conn, key, buf, &sz, NULL)) return false;
    if (val) *val = (buf[0] << 8) | buf[1];
    return true;
}

bool smc_read_ui32(io_connect_t conn, const char *key, uint32_t *val) {
    uint8_t buf[4] = {0};
    uint32_t sz = 0;
    if (!smc_read_bytes(conn, key, buf, &sz, NULL)) return false;
    if (val) *val = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
    return true;
}

bool smc_write_ui8(io_connect_t conn, const char *key, uint8_t val) {
    return smc_write_bytes(conn, key, &val, 1);
}

bool smc_write_ui32(io_connect_t conn, const char *key, uint32_t val) {
    uint8_t buf[4];
    buf[0] = (val >> 24) & 0xff;
    buf[1] = (val >> 16) & 0xff;
    buf[2] = (val >> 8) & 0xff;
    buf[3] = val & 0xff;
    return smc_write_bytes(conn, key, buf, 4);
}
