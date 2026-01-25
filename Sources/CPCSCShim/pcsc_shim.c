#include "include/pcsc_shim.h"
#include <dlfcn.h>
#include <string.h>

// PC/SC types (from winscard.h)
typedef int32_t LONG;
typedef uint32_t DWORD;
typedef char* LPSTR;
typedef const char* LPCSTR;
typedef void* SCARDCONTEXT;
typedef void* SCARDHANDLE;
typedef DWORD* LPDWORD;

typedef struct {
    DWORD dwProtocol;
    DWORD cbPciLength;
} SCARD_IO_REQUEST;

// PC/SC constants
#define SCARD_SCOPE_SYSTEM 2
#define SCARD_S_SUCCESS 0
#define SCARD_E_NO_READERS_AVAILABLE 0x8010002E
#define SCARD_E_NO_SMARTCARD 0x8010000C
#define SCARD_W_REMOVED_CARD 0x80100069
#define SCARD_SHARE_SHARED 2
#define SCARD_PROTOCOL_T0 1
#define SCARD_PROTOCOL_T1 2

// Function pointers for dynamic loading
typedef LONG (*SCardEstablishContextFn)(DWORD, const void*, const void*, SCARDCONTEXT*);
typedef LONG (*SCardReleaseContextFn)(SCARDCONTEXT);
typedef LONG (*SCardListReadersFn)(SCARDCONTEXT, LPCSTR, LPSTR, LPDWORD);
typedef LONG (*SCardConnectFn)(SCARDCONTEXT, LPCSTR, DWORD, DWORD, SCARDHANDLE*, LPDWORD);
typedef LONG (*SCardDisconnectFn)(SCARDHANDLE, DWORD);
typedef LONG (*SCardTransmitFn)(SCARDHANDLE, const SCARD_IO_REQUEST*, const uint8_t*, DWORD, SCARD_IO_REQUEST*, uint8_t*, LPDWORD);

static void* pcsc_lib = NULL;
static SCardEstablishContextFn fn_establish = NULL;
static SCardReleaseContextFn fn_release = NULL;
static SCardListReadersFn fn_list_readers = NULL;
static SCardConnectFn fn_connect = NULL;
static SCardDisconnectFn fn_disconnect = NULL;
static SCardTransmitFn fn_transmit = NULL;

static int load_pcsc(void) {
    if (pcsc_lib) return 1;
    
    pcsc_lib = dlopen("/System/Library/Frameworks/PCSC.framework/PCSC", RTLD_LAZY);
    if (!pcsc_lib) return 0;
    
    fn_establish = (SCardEstablishContextFn)dlsym(pcsc_lib, "SCardEstablishContext");
    fn_release = (SCardReleaseContextFn)dlsym(pcsc_lib, "SCardReleaseContext");
    fn_list_readers = (SCardListReadersFn)dlsym(pcsc_lib, "SCardListReaders");
    fn_connect = (SCardConnectFn)dlsym(pcsc_lib, "SCardConnect");
    fn_disconnect = (SCardDisconnectFn)dlsym(pcsc_lib, "SCardDisconnect");
    fn_transmit = (SCardTransmitFn)dlsym(pcsc_lib, "SCardTransmit");
    
    return (fn_establish && fn_release && fn_list_readers && fn_connect && fn_disconnect && fn_transmit);
}

int32_t pcsc_establish_context(uint32_t *context) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    SCARDCONTEXT ctx = NULL;
    LONG result = fn_establish(SCARD_SCOPE_SYSTEM, NULL, NULL, &ctx);
    if (result == SCARD_S_SUCCESS) {
        *context = (uint32_t)(uintptr_t)ctx;
        return PCSC_SUCCESS;
    }
    return PCSC_ERROR_NO_SERVICE;
}

int32_t pcsc_release_context(uint32_t context) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    LONG result = fn_release((SCARDCONTEXT)(uintptr_t)context);
    return (result == SCARD_S_SUCCESS) ? PCSC_SUCCESS : PCSC_ERROR_COMMUNICATION;
}

int32_t pcsc_list_readers(uint32_t context, char *readers, uint32_t *readers_len) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    DWORD len = *readers_len;
    LONG result = fn_list_readers((SCARDCONTEXT)(uintptr_t)context, NULL, readers, &len);
    *readers_len = (uint32_t)len;
    
    if (result == SCARD_S_SUCCESS) {
        return PCSC_SUCCESS;
    } else if (result == (LONG)SCARD_E_NO_READERS_AVAILABLE) {
        return PCSC_ERROR_NO_READERS;
    }
    return PCSC_ERROR_COMMUNICATION;
}

int32_t pcsc_connect(uint32_t context, const char *reader, uint32_t *card, uint32_t *protocol) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    SCARDHANDLE handle = NULL;
    DWORD active_protocol = 0;
    
    LONG result = fn_connect(
        (SCARDCONTEXT)(uintptr_t)context,
        reader,
        SCARD_SHARE_SHARED,
        SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
        &handle,
        &active_protocol
    );
    
    if (result == SCARD_S_SUCCESS) {
        *card = (uint32_t)(uintptr_t)handle;
        *protocol = (uint32_t)active_protocol;
        return PCSC_SUCCESS;
    } else if (result == (LONG)SCARD_E_NO_SMARTCARD || result == (LONG)SCARD_W_REMOVED_CARD) {
        return PCSC_ERROR_NO_CARD;
    }
    return PCSC_ERROR_COMMUNICATION;
}

int32_t pcsc_disconnect(uint32_t card, uint32_t disposition) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    LONG result = fn_disconnect((SCARDHANDLE)(uintptr_t)card, disposition);
    return (result == SCARD_S_SUCCESS) ? PCSC_SUCCESS : PCSC_ERROR_COMMUNICATION;
}

int32_t pcsc_transmit(uint32_t card, uint32_t protocol,
                      const uint8_t *send_buffer, uint32_t send_len,
                      uint8_t *recv_buffer, uint32_t *recv_len) {
    if (!load_pcsc()) return PCSC_ERROR_NO_SERVICE;
    
    SCARD_IO_REQUEST pioSendPci;
    pioSendPci.dwProtocol = protocol;
    pioSendPci.cbPciLength = sizeof(SCARD_IO_REQUEST);
    
    DWORD recvLen = *recv_len;
    
    LONG result = fn_transmit(
        (SCARDHANDLE)(uintptr_t)card,
        &pioSendPci,
        send_buffer,
        send_len,
        NULL,
        recv_buffer,
        &recvLen
    );
    
    *recv_len = (uint32_t)recvLen;
    
    return (result == SCARD_S_SUCCESS) ? PCSC_SUCCESS : PCSC_ERROR_COMMUNICATION;
}
