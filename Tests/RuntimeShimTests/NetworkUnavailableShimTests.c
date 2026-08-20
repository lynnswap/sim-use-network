// SPDX-License-Identifier: Apache-2.0

#include <assert.h>
#include <arpa/inet.h>
#include <string.h>

#define SIM_USE_NETWORK_TESTING 1
#define SIM_USE_NETWORK_SHIM_ABI_VERSION 2
#include "../../Sources/SimUseNetworkCore/Resources/RuntimeArtifacts/NetworkUnavailableShim.c"

static void test_ipv4_classification(void) {
    struct sockaddr_in address = {
        .sin_len = sizeof(struct sockaddr_in),
        .sin_family = AF_INET,
    };

    address.sin_addr.s_addr = htonl(INADDR_ANY);
    assert(!is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));

    address.sin_addr.s_addr = htonl(0x7f00002a);
    assert(!is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));

    address.sin_addr.s_addr = htonl(0x08080808);
    assert(is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));
}

static void test_ipv6_classification(void) {
    struct sockaddr_in6 address = {
        .sin6_len = sizeof(struct sockaddr_in6),
        .sin6_family = AF_INET6,
    };

    address.sin6_addr = in6addr_any;
    assert(!is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));

    address.sin6_addr = in6addr_loopback;
    assert(!is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));

    assert(inet_pton(AF_INET6, "2001:4860:4860::8888", &address.sin6_addr) == 1);
    assert(is_external_inet_address((const struct sockaddr *)&address, sizeof(address)));
}

static void test_short_and_unaligned_addresses(void) {
    struct sockaddr_in address = {
        .sin_len = sizeof(struct sockaddr_in),
        .sin_family = AF_INET,
        .sin_addr = { .s_addr = htonl(0x08080808) },
    };
    assert(!is_external_inet_address(
        (const struct sockaddr *)&address,
        offsetof(struct sockaddr, sa_family)
    ));
    assert(is_external_inet_address(
        (const struct sockaddr *)&address,
        sizeof(address) + 1
    ));

    unsigned char storage[sizeof(struct sockaddr_in) + 1];
    memcpy(storage + 1, &address, sizeof(address));
    assert(is_external_inet_address(
        (const struct sockaddr *)(storage + 1),
        sizeof(address)
    ));
}

static void test_explicit_loopback_sendto_ignores_external_udp_peer(void) {
    int receiver = socket(AF_INET, SOCK_DGRAM, 0);
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    assert(receiver >= 0 && sender >= 0);

    struct sockaddr_in loopback = {
        .sin_len = sizeof(struct sockaddr_in),
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr = { .s_addr = htonl(0x7f000001) },
    };
    assert(bind(receiver, (const struct sockaddr *)&loopback, sizeof(loopback)) == 0);
    socklen_t loopback_length = sizeof(loopback);
    assert(getsockname(receiver, (struct sockaddr *)&loopback, &loopback_length) == 0);

    struct sockaddr_in external = {
        .sin_len = sizeof(struct sockaddr_in),
        .sin_family = AF_INET,
        .sin_port = htons(9),
        .sin_addr = { .s_addr = htonl(0x08080808) },
    };
    assert(connect(sender, (const struct sockaddr *)&external, sizeof(external)) == 0);

    atomic_store_explicit(&current_state, 1, memory_order_release);
    const char payload = 'x';
    errno = 0;
    ssize_t result = sim_use_network_sendto(
        sender,
        &payload,
        sizeof(payload),
        0,
        (const struct sockaddr *)&loopback,
        sizeof(loopback)
    );
    assert(result >= 0 || errno != ENETDOWN);
    if (result >= 0) {
        char received = 0;
        assert(recv(receiver, &received, sizeof(received), 0) == sizeof(received));
        assert(received == payload);
    }

    close(sender);
    close(receiver);
}

static void test_all_route_socket_protocols_are_rejected(void) {
    atomic_store_explicit(&current_state, 1, memory_order_release);
    errno = 0;
    assert(sim_use_network_socket(PF_ROUTE, SOCK_RAW, 0) == -1);
    assert(errno == ENETDOWN);
    errno = 0;
    assert(sim_use_network_socket(PF_ROUTE, SOCK_RAW, AF_INET) == -1);
    assert(errno == ENETDOWN);
    errno = 0;
    assert(sim_use_network_socket(PF_ROUTE, SOCK_RAW, AF_INET6) == -1);
    assert(errno == ENETDOWN);
}

int main(void) {
    test_ipv4_classification();
    test_ipv6_classification();
    test_short_and_unaligned_addresses();
    test_explicit_loopback_sendto_ignores_external_udp_peer();
    test_all_route_socket_protocols_are_rejected();
    return 0;
}
