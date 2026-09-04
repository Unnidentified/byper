#ifndef SMC_H
#define SMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_INDEX     8
#define SMC_CMD_READ_KEYINFO   9

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint8_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuMCL;
    uint32_t cpuCL;
    uint8_t maxNotify;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

// SMC Key Type constants
#define SMC_TYPE_UI8   0x75693820  // 'ui8 '
#define SMC_TYPE_UI16  0x75693136  // 'ui16'
#define SMC_TYPE_UI32  0x75693332  // 'ui32'
#define SMC_TYPE_SI8   0x73693820  // 'si8 '
#define SMC_TYPE_SI16  0x73693136  // 'si16'
#define SMC_TYPE_HEX   0x6865785f  // 'hex_'
#define SMC_TYPE_FLT   0x666c7420  // 'flt '
#define SMC_TYPE_FLAG  0x666c6167  // 'flag'

// Helper conversion
uint32_t smc_str_to_key(const char *str);
void smc_key_to_str(uint32_t key, char *str);

// SMC Connection Management
io_connect_t smc_open(void);
void smc_close(io_connect_t conn);

// SMC Core Operations
bool smc_get_key_info(io_connect_t conn, const char *key, SMCKeyData_keyInfo_t *info);
bool smc_read_bytes(io_connect_t conn, const char *key, uint8_t *buffer, uint32_t *size, char *typeOut);
bool smc_write_bytes(io_connect_t conn, const char *key, const uint8_t *buffer, uint32_t size);

// High-level SMC helpers
bool smc_read_ui8(io_connect_t conn, const char *key, uint8_t *val);
bool smc_read_ui16(io_connect_t conn, const char *key, uint16_t *val);
bool smc_read_ui32(io_connect_t conn, const char *key, uint32_t *val);
bool smc_write_ui8(io_connect_t conn, const char *key, uint8_t val);
bool smc_write_ui32(io_connect_t conn, const char *key, uint32_t val);

#endif // SMC_H
