/* SPDX-License-Identifier: MIT */
/*
 * atsend - minimal raw AT sender/reader, for ground-truth byte capture.
 *   atsend <tty> <cmd> <hard_ms> <outfile>
 * Opens the tty raw, flushes, writes "<cmd>\r", reads everything until
 * "\r\nOK\r\n" / "\r\nERROR\r\n" seen or hard_ms elapsed, dumps raw bytes.
 * Also records per-read chunk boundaries (as \n#CHUNK n len\n) so partial
 * reads / interleaving can be spotted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/select.h>
#include <time.h>

static long now_ms(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return (long)ts.tv_sec*1000 + ts.tv_nsec/1000000;
}

int main(int argc,char**argv){
    if(argc<5){ fprintf(stderr,"usage: %s <tty> <cmd> <hard_ms> <outfile>\n",argv[0]); return 5; }
    const char*dev=argv[1]; const char*cmd=argv[2];
    long hard=atol(argv[3]); const char*out=argv[4];
    int fd=open(dev,O_RDWR|O_NOCTTY|O_NONBLOCK);
    if(fd<0){ fprintf(stderr,"open: %s\n",strerror(errno)); return 4; }
    struct termios oldt,t;
    if(tcgetattr(fd,&oldt)!=0){ perror("tcgetattr"); return 4; }
    t=oldt; cfmakeraw(&t);
    cfsetispeed(&t,B115200); cfsetospeed(&t,B115200);
    t.c_cflag|=(CLOCAL|CREAD); t.c_cc[VMIN]=0; t.c_cc[VTIME]=0;
    if(tcsetattr(fd,TCSANOW,&t)!=0){ perror("tcsetattr"); return 4; }
    tcflush(fd,TCIOFLUSH);

    FILE*f=fopen(out,"wb");
    if(!f){ perror("fopen"); return 4; }

    char wbuf[512]; int wl=snprintf(wbuf,sizeof wbuf,"%s\r",cmd);
    long t0=now_ms();
    if(write(fd,wbuf,wl)!=wl) fprintf(f,"#WRITE ERR %s\n",strerror(errno));

    char tail[512]; int tl=0; memset(tail,0,sizeof tail);
    char buf[8192]; int chunk=0,complete=0;
    while(now_ms()-t0 < hard){
        fd_set rf; FD_ZERO(&rf); FD_SET(fd,&rf);
        struct timeval tv={0,200000};
        int r=select(fd+1,&rf,NULL,NULL,&tv);
        if(r<=0) continue;
        int n=(int)read(fd,buf,sizeof buf);
        if(n<=0) continue;
        chunk++;
        fprintf(f,"\n#CHUNK %d len=%d t=%ld\n",chunk,n,now_ms()-t0);
        fwrite(buf,1,n,f);
        for(int i=0;i<n;i++){
            if(tl<(int)sizeof tail-1){ tail[tl++]=buf[i]; tail[tl]=0; }
            else { memmove(tail,tail+1,sizeof tail-2); tail[tl-1]=buf[i]; tail[tl]=0; }
        }
        if(strstr(tail,"\r\nOK\r\n")||strstr(tail,"\r\nERROR\r\n")) { complete=1; break; }
    }
    fprintf(f,"\n#END complete=%d elapsed=%ld chunks=%d\n",complete,now_ms()-t0,chunk);
    fclose(f);
    tcsetattr(fd,TCSANOW,&oldt);
    close(fd);
    return complete?0:3;
}
