#ifndef PCSC_SHIM_H
#define PCSC_SHIM_H

#include <stdint.h>
#include <stddef.h>

// Context management
int32_t pcsc_establish_context(uint32_t *context);
int32_t pcsc_release_context(uint32_t context);

// Reader enumeration
int32_t pcsc_list_readers(uint32_t context, char *readers, uint32_t *readers_len);

// Card connection
int32_t pcsc_connect(uint32_t context, const char *reader, uint32_t *card, uint32_t *protocol);
int32_t pcsc_disconnect(uint32_t card, uint32_t disposition);

// Card communication
int32_t pcsc_transmit(uint32_t card, uint32_t protocol,
                      const uint8_t *send_buffer, uint32_t send_len,
                      uint8_t *recv_buffer, uint32_t *recv_len);

// Error codes
#define PCSC_SUCCESS 0
#define PCSC_ERROR_NO_SERVICE -1
#define PCSC_ERROR_NO_READERS -2
#define PCSC_ERROR_NO_CARD -3
#define PCSC_ERROR_COMMUNICATION -4

#endif // PCSC_SHIM_H
