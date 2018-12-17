/*  Copyright 2007-2017 the original vcontrold development team

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#define _GNU_SOURCE

#include <sys/time.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>
#ifndef __CYGWIN__
// I'm not sure about this cpp defines, can some check tht? -fn-
#ifdef __linux__
#include <linux/tcp.h> // do we realy need this? Not sure for Linux -fn-
#endif
#if defined (__FreeBSD__) || defined(__APPLE__)
#include <netinet/in.h>
#include <netinet/tcp.h> // TCP_NODELAY is defined there -fn-
#endif
#endif

#include "socket.h"
#include "common.h"
#include "vclient.h"

// include readline

static ssize_t my_read(int fd, char *ptr)
{

    static ssize_t read_cnt = 0;
    static char *read_ptr;
    static char read_buf[MAXLINE];

    if (read_cnt <= 0) {
again:
        if ((read_cnt = read(fd, read_buf, sizeof(read_buf))) < 0) {
            if (errno == EINTR) {
                goto again;
            }
            return -1;
        } else if (read_cnt == 0) {
            return 0;
        }
        read_ptr = read_buf;
    }

    read_cnt--;
    *ptr = *read_ptr++;
    return 1;
}

ssize_t readline(int fd, void *vptr, size_t maxlen)
{
    int n;
    ssize_t rc;
    char c;
    char *ptr;

    ptr = vptr;
    for (n = 1; n < maxlen; n++) {
        if ( (rc = my_read(fd, &c)) == 1) {
            *ptr++ = c;
            if (c == '\n') {
                // newline is stored, like fgets()
                break;
            }
        } else if (rc == 0) {
            if (n == 1) {
                // EOF, no data read
                return 0;
            }
            else {
                // EOF, some data was read
                break;
            }
        } else {
            // error, errno set by read()
            return -1;
        }
    }

    *ptr = 0; // null terminate like fgets()
    return n;
}

// end readline

ssize_t Readline(int fd, void *ptr, size_t maxlen)
{
    ssize_t n;

    if ((n = readline(fd, ptr, maxlen)) < 0) {
        logIT1(LOG_ERR, "Error reading from socket");
        return 0;
    }
    return n;
}
