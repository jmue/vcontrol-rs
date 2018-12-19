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

// Client routines for vcontrold queries

#include <syslog.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <time.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>
#include <ctype.h>

#include "client.h"
#include "prompt.h"
#include "common.h"
#include "bindings.h"

static void sig_alrm(int);
static jmp_buf  env_alrm;

int sendTrList(int sockfd, trPtr ptr);

trPtr newTrNode(trPtr ptr)
{
    trPtr nptr;

    if (ptr && ptr->next) {
        return newTrNode(ptr->next);
    }

    nptr = calloc(1, sizeof(*ptr));
    if (! nptr) {
        fprintf(stderr, "malloc failed\n");
        exit(1);
    }

    if (ptr) {
        ptr->next = nptr;
    }

    return nptr;
}

trPtr sendCmdFile(int sockfd, const char *filename)
{
    FILE *filePtr;
    char line[MAXBUF];
    trPtr ptr;
    trPtr startPtr = NULL;

    if (! (filePtr = fopen(filename, "r"))) {
        return NULL;
    } else {
        logIT(LOG_INFO, "Opened command file %s", filename);
    }

    bzero(line, sizeof(line));
    while (fgets(line, MAXBUF - 1, filePtr)) {
        ptr = newTrNode(startPtr);
        if (! startPtr) {
            startPtr = ptr;
        }
        ptr->cmd = calloc(strlen(line), sizeof(char));
        strncpy(ptr->cmd, line, strlen(line) - 1);
    }

    if (! sendTrList(sockfd, startPtr)) {
        // Something with the communication went wrong
        return NULL;
    }

    return startPtr;
}

trPtr sendCmds(int sockfd, char *commands)
{
    char *sptr;
    trPtr ptr;
    trPtr startPtr = NULL;

    sptr = strtok(commands, ",");
    do {
        ptr = newTrNode(startPtr);
        if (! startPtr) {
            startPtr = ptr;
        }
        ptr->cmd = calloc(strlen(sptr) + 1, sizeof(char));
        strncpy(ptr->cmd, sptr, strlen(sptr));
    } while ((sptr = strtok(NULL, ",")) != NULL);

    if (! sendTrList(sockfd, startPtr))
    {
        // Something with the communication went wrong
        return NULL;
    }

    return startPtr;
}

int sendTrList(int sockfd, trPtr ptr)
{
    char string[1000 + 1];
    char *sptr;
    char *dumPtr;

    if (recvSync(sockfd, PROMPT, &sptr) <= 0) {
        free(sptr);
        return 0;
    }

    while (ptr) {
        //bzero(string,sizeof(string));
        snprintf(string, sizeof(string), "%s\n", ptr->cmd);

        if (sendServer(sockfd, string, strlen(string)) <= 0) {
            return 0;
        }

        //bzero(string,sizeof(string));
        logIT(LOG_INFO, "SEND:%s", ptr->cmd);
        if (recvSync(sockfd, PROMPT, &sptr) <= 0) {
            free(sptr);
            return 0;
        }

        ptr->raw = sptr;
        if (iscntrl(*(ptr->raw + strlen(ptr->raw) - 1))) {
            *(ptr->raw + strlen(ptr->raw) - 1) = '\0';
        }

        dumPtr = calloc(strlen(sptr) + 20, sizeof(char));
        snprintf(dumPtr, (strlen(sptr) + 20) * sizeof(char), "RECV:%s", sptr);
        logIT1(LOG_INFO, dumPtr);
        free(dumPtr);

        // We fill errors and result
        if (strstr(ptr->raw, ERR) == ptr->raw) {
            ptr->err = ptr->raw;
            fprintf(stderr, "SRV %s\n", ptr->err);
        } else {
            // Here, we search the first word in raw and save it as result
            char *rptr;
            char len;
            rptr = strchr(ptr->raw, ' ');
            if (! rptr) {
                rptr = ptr->raw + strlen(ptr->raw);
            }

            len = rptr - ptr->raw;
            ptr->result = atof(ptr->raw);
            ptr->err = NULL;
        }

        ptr = ptr->next;
    }

    return 1;
}

static void sig_alrm(int signo)
{
    longjmp(env_alrm, 1);
}
