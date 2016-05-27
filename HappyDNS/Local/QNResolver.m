//
//  QNResolver.m
//  HappyDNS
//
//  Created by bailong on 15/6/23.
//  Copyright (c) 2015年 Qiniu Cloud Storage. All rights reserved.
//

#include <arpa/inet.h>
#include <resolv.h>
#include <string.h>

#include <netdb.h>
#include <netinet/in.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>

#import "QNDomain.h"
#import "QNIP.h"
#import "QNRecord.h"
#import "QNResolver.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#endif

@interface QNResolver ()
@property (nonatomic) NSString *address;
@end

static BOOL isV6(NSString *address) {
    return strchr(address.UTF8String, ':') != NULL;
}

static NSArray *query_ip_v4(res_state res, const char *host) {
    u_char answer[1500];
    int len = res_nquery(res, host, ns_c_in, ns_t_a, answer, sizeof(answer));

    ns_msg handle;
    ns_initparse(answer, len, &handle);

    int count = ns_msg_count(handle, ns_s_an);
    if (count <= 0) {
        res_ndestroy(res);
        return nil;
    }
    NSMutableArray *array = [[NSMutableArray alloc] initWithCapacity:count];
    char buf[32];
    char cnameBuf[NS_MAXDNAME];
    memset(cnameBuf, 0, sizeof(cnameBuf));
    for (int i = 0; i < count; i++) {
        ns_rr rr;
        if (ns_parserr(&handle, ns_s_an, i, &rr) != 0) {
            res_ndestroy(res);
            return nil;
        }
        int t = ns_rr_type(rr);
        int ttl = ns_rr_ttl(rr);
        NSString *val;
        if (t == ns_t_a) {
            const char *p = inet_ntop(AF_INET, ns_rr_rdata(rr), buf, 32);
            val = [NSString stringWithUTF8String:p];
        } else if (t == ns_t_cname) {
            int x = ns_name_uncompress(answer, &(answer[len]), ns_rr_rdata(rr), cnameBuf, sizeof(cnameBuf));
            if (x <= 0) {
                continue;
            }
            val = [NSString stringWithUTF8String:cnameBuf];
            memset(cnameBuf, 0, sizeof(cnameBuf));
        } else {
            continue;
        }
        QNRecord *record = [[QNRecord alloc] init:val ttl:ttl type:t];
        [array addObject:record];
    }
    res_ndestroy(res);
    return array;
}

static int setup_dns_server(res_state res, NSString *dns_server) {
    int r = res_ninit(res);
    if (r != 0) {
        return r;
    }
    if (dns_server == NULL) {
        return 0;
    }

    union res_sockaddr_union server = {0};

    struct addrinfo hints = {0}, *ai = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int ret = getaddrinfo(dns_server.UTF8String, "53", &hints, &ai);
    if (ret != 0) {
        return -1;
    }
    int family = ai->ai_family;

    if (family == AF_INET6) {
        ((struct sockaddr_in6 *)ai->ai_addr)->sin6_port = htons(53);
        server.sin6 = *((struct sockaddr_in6 *)ai->ai_addr);
    } else {
        server.sin = *((struct sockaddr_in *)ai->ai_addr);
    }

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
    float sysVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
    if (sysVersion < 9.0 && sysVersion >= 8.0 && family == AF_INET) {
        if ([QNIP isV6]) {
            freeaddrinfo(ai);
            ai = NULL;
            bzero(&hints, 0);
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            char buf[64] = {0};
            qn_nat64(buf, sizeof(buf), dns_server.UTF8String);
            int ret = getaddrinfo(buf, "53", &hints, &ai);
            if (ret != 0) {
                return -1;
            }
            ((struct sockaddr_in6 *)ai->ai_addr)->sin6_port = htons(53);
            server.sin6 = *((struct sockaddr_in6 *)ai->ai_addr);
        }
    }
#endif

    freeaddrinfo(ai);
    res_setservers(res, &server, 1);
    return 0;
}

@implementation QNResolver
- (instancetype)initWithAddres:(NSString *)address {
    if (self = [super init]) {
        _address = address;
    }
    return self;
}

- (NSArray *)query:(QNDomain *)domain networkInfo:(QNNetworkInfo *)netInfo error:(NSError *__autoreleasing *)error {
    struct __res_state res;

    int r = setup_dns_server(&res, _address);
    if (r != 0) {
        return nil;
    }

    NSArray *ret = query_ip_v4(&res, [domain.domain cStringUsingEncoding:NSUTF8StringEncoding]);
    if (ret != nil && ret.count != 0) {
        return ret;
    }
    return nil;
}

+ (instancetype)systemResolver {
    return [[QNResolver alloc] initWithAddres:nil];
}

+ (NSString *)systemDnsServer {
    struct __res_state res;
    int r = res_ninit(&res);
    if (r != 0) {
        return nil;
    }

    union res_sockaddr_union server[MAXNS] = {0};
    r = res_getservers(&res, server, MAXNS);
    res_ndestroy(&res);
    if (r <= 0) {
        return nil;
    }

    int family = server[0].sin.sin_family;
    char buf[64] = {0};
    const void *addr;
    if (family == AF_INET6) {
        addr = &server[0].sin6.sin6_addr;
    } else {
        addr = &server[0].sin.sin_addr;
    }
    const char *p = inet_ntop(family, addr, buf, sizeof(buf));
    if (p == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:p];
}

@end
