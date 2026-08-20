// SPDX-License-Identifier: Apache-2.0

#include <errno.h>
#include <dispatch/dispatch.h>
#include <netinet/in.h>
#include <notify.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

#ifndef SIM_USE_NETWORK_SHIM_ABI_VERSION
#error "SIM_USE_NETWORK_SHIM_ABI_VERSION must be provided by the artifact compiler"
#endif

#define SIM_USE_NETWORK_CONCAT_INNER(left, right) left##right
#define SIM_USE_NETWORK_CONCAT(left, right) SIM_USE_NETWORK_CONCAT_INNER(left, right)

__attribute__((visibility("default")))
const uint32_t SIM_USE_NETWORK_CONCAT(
    SimUseNetworkShimABIVersion_,
    SIM_USE_NETWORK_SHIM_ABI_VERSION
) = SIM_USE_NETWORK_SHIM_ABI_VERSION;

static int state_token = -1;
static int ready_token = -1;
static atomic_flag state_failure_reported = ATOMIC_FLAG_INIT;
static atomic_uint current_state = 1;
#define SIM_USE_NETWORK_TRACKED_FD_LIMIT 65536
static atomic_uchar pending_external_connectx[SIM_USE_NETWORK_TRACKED_FD_LIMIT];

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "network state must be lock-free");

static void report_state_failure(const char *message) {
    if (!atomic_flag_test_and_set(&state_failure_reported)) {
        fprintf(stderr, "sim-use-network shim: %s; external network remains unavailable\n", message);
    }
}

static void mark_state_failure(const char *message) {
    atomic_store_explicit(&current_state, 1, memory_order_release);
    if (ready_token >= 0) {
        (void)notify_set_state(ready_token, 0);
    }
    report_state_failure(message);
}

static void update_state(int token) {
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK || state > 1) {
        mark_state_failure("notify state read failed");
        return;
    }
    atomic_store_explicit(&current_state, state, memory_order_release);
    if (ready_token < 0 ||
        notify_set_state(ready_token, state + 1) != NOTIFY_STATUS_OK) {
        mark_state_failure("shim state acknowledgement failed");
    }
}

static bool register_state(void) {
    const char *name = getenv("SIM_USE_NETWORK_STATE_NAME");
    if (name == NULL || name[0] == '\0') {
        mark_state_failure("SIM_USE_NETWORK_STATE_NAME is missing");
        return false;
    }
    const char *ready_name = getenv("SIM_USE_NETWORK_READY_NAME");
    if (ready_name == NULL || ready_name[0] == '\0') {
        mark_state_failure("SIM_USE_NETWORK_READY_NAME is missing");
        return false;
    }
    if (notify_register_check(ready_name, &ready_token) != NOTIFY_STATUS_OK) {
        ready_token = -1;
        mark_state_failure("shim readiness registration failed");
        return false;
    }
    if (notify_register_dispatch(
            name,
            &state_token,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
            ^(int token) { update_state(token); }
        ) != NOTIFY_STATUS_OK) {
        notify_cancel(ready_token);
        ready_token = -1;
        state_token = -1;
        mark_state_failure("notify registration failed");
        return false;
    }
    update_state(state_token);
    return state_token >= 0 && ready_token >= 0;
}

#ifndef SIM_USE_NETWORK_TESTING
__attribute__((constructor))
static void initialize_sim_use_network_shim(void) {
    if (!register_state()) {
        mark_state_failure("state registration did not complete");
    }
}
#endif

static bool network_is_unavailable(void) {
    return atomic_load_explicit(&current_state, memory_order_acquire) == 1;
}

static bool is_ipv4_local(const struct in_addr *address) {
    return address != NULL && (
        address->s_addr == htonl(INADDR_ANY) ||
        (ntohl(address->s_addr) >> 24) == 127
    );
}

static bool is_ipv6_local(const struct in6_addr *address) {
    if (address == NULL) {
        return false;
    }
    if (IN6_IS_ADDR_LOOPBACK(address) || IN6_IS_ADDR_UNSPECIFIED(address)) {
        return true;
    }
    if (IN6_IS_ADDR_V4MAPPED(address)) {
        struct in_addr mapped;
        memcpy(&mapped.s_addr, &address->s6_addr[12], sizeof(mapped.s_addr));
        return is_ipv4_local(&mapped);
    }
    return false;
}

static bool is_external_inet_address(
    const struct sockaddr *address,
    socklen_t length
) {
    if (address == NULL ||
        length < offsetof(struct sockaddr, sa_family) + sizeof(address->sa_family)) {
        return false;
    }
    if (address->sa_family == AF_INET) {
        if (length < sizeof(struct sockaddr_in)) {
            return false;
        }
        struct sockaddr_in ipv4;
        memcpy(&ipv4, address, sizeof(ipv4));
        return !is_ipv4_local(&ipv4.sin_addr);
    }
    if (address->sa_family == AF_INET6) {
        if (length < sizeof(struct sockaddr_in6)) {
            return false;
        }
        struct sockaddr_in6 ipv6;
        memcpy(&ipv6, address, sizeof(ipv6));
        return !is_ipv6_local(&ipv6.sin6_addr);
    }
    return false;
}

static bool valid_tracked_descriptor(int descriptor) {
    return descriptor >= 0 && descriptor < SIM_USE_NETWORK_TRACKED_FD_LIMIT;
}

static void set_pending_external_connectx(int descriptor, bool pending) {
    if (valid_tracked_descriptor(descriptor)) {
        atomic_store_explicit(
            &pending_external_connectx[descriptor],
            pending ? 1 : 0,
            memory_order_release
        );
    }
}

static bool has_pending_external_connectx(int descriptor) {
    return valid_tracked_descriptor(descriptor) &&
        atomic_load_explicit(
            &pending_external_connectx[descriptor],
            memory_order_acquire
        ) == 1;
}

static bool should_reject_external_io(int socket_descriptor) {
    if (!network_is_unavailable()) {
        return false;
    }

    struct sockaddr_storage peer;
    socklen_t peer_length = sizeof(peer);
    if (getpeername(
            socket_descriptor,
            (struct sockaddr *)&peer,
            &peer_length
        ) == 0) {
        bool external = is_external_inet_address(
            (const struct sockaddr *)&peer,
            peer_length
        );
        if (!external) {
            set_pending_external_connectx(socket_descriptor, false);
        }
        return external;
    }
    if (has_pending_external_connectx(socket_descriptor) && errno == ENOTCONN) {
        return true;
    }
    if (has_pending_external_connectx(socket_descriptor)) {
        set_pending_external_connectx(socket_descriptor, false);
    }
    if (errno != ENOTCONN) {
        return false;
    }

    // connectx may defer an external connection until the first write. In that
    // state getpeername is ENOTCONN. Darwin has already selected a source at
    // this point, so classify that address: loopback remains local while a
    // LAN/global source identifies a pending external connection.
    struct sockaddr_storage local;
    socklen_t local_length = sizeof(local);
    if (getsockname(
            socket_descriptor,
            (struct sockaddr *)&local,
            &local_length
        ) != 0 ||
        local_length < offsetof(struct sockaddr, sa_family) + sizeof(local.ss_family)) {
        return false;
    }
    return is_external_inet_address(
        (const struct sockaddr *)&local,
        local_length
    );
}

static int sim_use_network_socket(int domain, int type, int protocol) {
    if (network_is_unavailable() &&
        domain == PF_ROUTE &&
        type == SOCK_RAW) {
        errno = ENETDOWN;
        return -1;
    }
    int descriptor = socket(domain, type, protocol);
    if (descriptor >= 0) {
        set_pending_external_connectx(descriptor, false);
    }
    return descriptor;
}

static int sim_use_network_connect(
    int socket_descriptor,
    const struct sockaddr *address,
    socklen_t length
) {
    if (network_is_unavailable() && is_external_inet_address(address, length)) {
        errno = ENETDOWN;
        return -1;
    }
    return connect(socket_descriptor, address, length);
}

static int sim_use_network_connectx(
    int socket_descriptor,
    const sa_endpoints_t *endpoints,
    sae_associd_t association_id,
    unsigned int flags,
    const struct iovec *iovecs,
    unsigned int iovec_count,
    size_t *bytes_written,
    sae_connid_t *connection_id
) {
    if (network_is_unavailable() &&
        endpoints != NULL &&
        is_external_inet_address(endpoints->sae_dstaddr, endpoints->sae_dstaddrlen)) {
        errno = ENETDOWN;
        return -1;
    }
    int result = connectx(
        socket_descriptor,
        endpoints,
        association_id,
        flags,
        iovecs,
        iovec_count,
        bytes_written,
        connection_id
    );
    if (result == 0 &&
        endpoints != NULL &&
        is_external_inet_address(endpoints->sae_dstaddr, endpoints->sae_dstaddrlen) &&
        (flags & CONNECT_RESUME_ON_READ_WRITE) != 0) {
        set_pending_external_connectx(socket_descriptor, true);
    }
    return result;
}

static int sim_use_network_close(int descriptor) {
    set_pending_external_connectx(descriptor, false);
    return close(descriptor);
}

static int sim_use_network_dup(int descriptor) {
    int duplicated = dup(descriptor);
    if (duplicated >= 0) {
        set_pending_external_connectx(
            duplicated,
            has_pending_external_connectx(descriptor)
        );
    }
    return duplicated;
}

static int sim_use_network_dup2(int descriptor, int replacement) {
    int duplicated = dup2(descriptor, replacement);
    if (duplicated >= 0) {
        set_pending_external_connectx(
            duplicated,
            has_pending_external_connectx(descriptor)
        );
    }
    return duplicated;
}

static ssize_t sim_use_network_send(
    int socket_descriptor,
    const void *buffer,
    size_t length,
    int flags
) {
    if (should_reject_external_io(socket_descriptor)) {
        errno = ENETDOWN;
        return -1;
    }
    return send(socket_descriptor, buffer, length, flags);
}

static ssize_t sim_use_network_sendto(
    int socket_descriptor,
    const void *buffer,
    size_t length,
    int flags,
    const struct sockaddr *destination,
    socklen_t destination_length
) {
    bool reject = false;
    if (network_is_unavailable()) {
        reject = destination == NULL
            ? should_reject_external_io(socket_descriptor)
            : is_external_inet_address(destination, destination_length);
    }
    if (reject) {
        errno = ENETDOWN;
        return -1;
    }
    return sendto(
        socket_descriptor,
        buffer,
        length,
        flags,
        destination,
        destination_length
    );
}

static ssize_t sim_use_network_sendmsg(
    int socket_descriptor,
    const struct msghdr *message,
    int flags
) {
    if (!network_is_unavailable()) {
        return sendmsg(socket_descriptor, message, flags);
    }
    const struct sockaddr *destination = message == NULL
        ? NULL
        : (const struct sockaddr *)message->msg_name;
    socklen_t destination_length = message == NULL
        ? 0
        : (socklen_t)message->msg_namelen;
    bool reject = destination == NULL
        ? should_reject_external_io(socket_descriptor)
        : is_external_inet_address(destination, destination_length);
    if (reject) {
        errno = ENETDOWN;
        return -1;
    }
    return sendmsg(socket_descriptor, message, flags);
}

static ssize_t sim_use_network_write(
    int file_descriptor,
    const void *buffer,
    size_t length
) {
    if (should_reject_external_io(file_descriptor)) {
        errno = ENETDOWN;
        return -1;
    }
    return write(file_descriptor, buffer, length);
}

static ssize_t sim_use_network_writev(
    int file_descriptor,
    const struct iovec *iovecs,
    int iovec_count
) {
    if (should_reject_external_io(file_descriptor)) {
        errno = ENETDOWN;
        return -1;
    }
    return writev(file_descriptor, iovecs, iovec_count);
}

#define SIM_USE_NETWORK_INTERPOSE(replacement, replacee) \
    _Static_assert( \
        __builtin_types_compatible_p(__typeof__(&(replacement)), __typeof__(&(replacee))), \
        "interposed function signature mismatch" \
    ); \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } sim_use_network_interpose_##replacee \
        __attribute__((section("__DATA,__interpose"))) = { \
            (const void *)(unsigned long)&replacement, \
            (const void *)(unsigned long)&replacee, \
        }

#ifndef SIM_USE_NETWORK_TESTING
SIM_USE_NETWORK_INTERPOSE(sim_use_network_socket, socket);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_connect, connect);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_connectx, connectx);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_close, close);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_dup, dup);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_dup2, dup2);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_send, send);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_sendto, sendto);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_sendmsg, sendmsg);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_write, write);
SIM_USE_NETWORK_INTERPOSE(sim_use_network_writev, writev);
#endif
