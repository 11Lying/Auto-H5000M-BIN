/* SPDX-License-Identifier: MIT */
/*
 * qscan-worker: minimal, single-purpose long-running AT reader for QSCAN.
 *
 * Usage:
 *   qscan-worker <tty> <mode 1-3> <rawfile>
 *                [idle_stall_ms=30000] [hard_ms=200000] [drain_ms=2000]
 *
 * Behaviour:
 *   - opens <tty> raw @115200 8N1 (usb-serial ignores baud, raw is what matters)
 *   - flushes input, writes "AT+QSCAN=<mode>\r"
 *   - select()-based read loop, appends everything to <rawfile>
 *   - completion = buffer contains "\r\nOK\r\n" / "ERROR" / "+CME ERROR" / "+CMS ERROR"
 *   - idle stall  = no byte for idle_stall_ms while NOT yet complete  -> timeout(3)
 *   - hard cap    = total runtime > hard_ms                           -> timeout(3)
 *   - after completion, DRAIN: keep reading until drain_ms of silence
 *     (guarantees no QSCAN residue is left in the port for the next reader)
 *   - restores original termios, closes.
 *
 * Exit codes: 0 OK, 2 modem ERROR, 3 timeout/stall, 4 open/serial error, 5 usage
 * This program only ever talks to the given tty. No modem/QMI/SMS logic.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>

static long now_ms(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return (long)ts.tv_sec*1000 + ts.tv_nsec/1000000;
}

int main(int argc, char **argv){
    if(argc < 4){
        fprintf(stderr,"usage: %s <tty> <mode 1-3> <rawfile> [idle_stall_ms] [hard_ms] [drain_ms]\n",argv[0]);
        return 5;
    }
    const char *dev=argv[1];
    int mode=atoi(argv[2]);
    const char *rawpath=argv[3];
    long idle_stall = argc>4 ? atol(argv[4]) : 30000;
    long hard_ms    = argc>5 ? atol(argv[5]) : 200000;
    long drain_ms   = argc>6 ? atol(argv[6]) : 2000;
    /* mode 0 == self-test (ATI); mode 9 == read-only drain (send nothing) */
    if(!(mode==0||mode==9||(mode>=1&&mode<=3))){ fprintf(stderr,"bad mode %d (0-3,9)\n",mode); return 5; }

    int fd=open(dev,O_RDWR|O_NOCTTY|O_NONBLOCK);
    if(fd<0){ fprintf(stderr,"open %s: %s\n",dev,strerror(errno)); return 4; }

    struct termios oldt, t;
    if(tcgetattr(fd,&oldt)!=0){ fprintf(stderr,"tcgetattr: %s\n",strerror(errno)); close(fd); return 4; }
    t=oldt;
    cfmakeraw(&t);
    cfsetispeed(&t,B115200);
    cfsetospeed(&t,B115200);
    t.c_cflag |= (CLOCAL|CREAD);
    t.c_cc[VMIN]=0; t.c_cc[VTIME]=0;
    if(tcsetattr(fd,TCSANOW,&t)!=0){ fprintf(stderr,"tcsetattr: %s\n",strerror(errno)); close(fd); return 4; }
    tcflush(fd,TCIOFLUSH);

    FILE *raw=fopen(rawpath,"w");
    if(!raw){ fprintf(stderr,"open raw %s: %s\n",rawpath,strerror(errno)); tcsetattr(fd,TCSANOW,&oldt); close(fd); return 4; }

    char cmd[32]; int cl=0;
    if(mode==0)      cl=snprintf(cmd,sizeof cmd,"ATI\r");
    else if(mode==9) cl=0;                                  /* read-only: send nothing */
    else             cl=snprintf(cmd,sizeof cmd,"AT+QSCAN=%d\r",mode);
    if(cl>0 && write(fd,cmd,cl)!=cl){ fprintf(stderr,"write cmd: %s\n",strerror(errno)); }

    /* rolling tail buffer for terminator detection */
    char tail[256]; int tl=0; memset(tail,0,sizeof tail);
    char buf[4096];
    long start=now_ms(), last=start;
    int complete=0, iserr=0;

    for(;;){
        long n=now_ms();
        if(!complete && (n-start)>hard_ms){ break; }               /* hard watchdog */
        if(!complete && (n-last)>idle_stall){ break; }             /* stalled, no OK */
        if(complete && (n-last)>drain_ms){ break; }                /* drained */

        fd_set rf; FD_ZERO(&rf); FD_SET(fd,&rf);
        struct timeval tv; tv.tv_sec=0; tv.tv_usec=200000;         /* 200ms tick */
        int s=select(fd+1,&rf,NULL,NULL,&tv);
        if(s<0){ if(errno==EINTR) continue; break; }
        if(s==0) continue;

        int r=read(fd,buf,sizeof buf);
        if(r<0){ if(errno==EAGAIN||errno==EINTR) continue; break; }
        if(r==0) continue;
        fwrite(buf,1,r,raw); fflush(raw);
        last=now_ms();

        /* update rolling tail */
        for(int i=0;i<r;i++){
            if(tl<(int)sizeof(tail)-1){ tail[tl++]=buf[i]; }
            else { memmove(tail,tail+1,sizeof(tail)-2); tail[sizeof(tail)-2]=buf[i]; }
        }
        tail[tl<(int)sizeof(tail)?tl:(int)sizeof(tail)-1]=0;

        if(!complete){
            if(strstr(tail,"\r\nOK\r\n")){ complete=1; iserr=0; }
            else if(strstr(tail,"+CME ERROR")||strstr(tail,"+CMS ERROR")||strstr(tail,"\r\nERROR\r\n")){ complete=1; iserr=1; }
        }
    }

    /* final short drain regardless, to be safe */
    long dstart=now_ms();
    for(;;){
        if(now_ms()-dstart>drain_ms) break;
        fd_set rf; FD_ZERO(&rf); FD_SET(fd,&rf);
        struct timeval tv; tv.tv_sec=0; tv.tv_usec=200000;
        int s=select(fd+1,&rf,NULL,NULL,&tv);
        if(s<=0) continue;
        int r=read(fd,buf,sizeof buf);
        if(r<=0) break;
        fwrite(buf,1,r,raw); fflush(raw);
        dstart=now_ms();   /* reset: keep draining while data flows */
    }

    fclose(raw);
    tcsetattr(fd,TCSANOW,&oldt);
    close(fd);

    long elapsed=now_ms()-start;
    fprintf(stderr,"elapsed_ms=%ld complete=%d err=%d\n",elapsed,complete,iserr);
    if(!complete) return 3;
    return iserr?2:0;
}
