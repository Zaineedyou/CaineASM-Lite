#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
typedef struct { char *data; size_t len, cap; } sbuf;
extern sbuf ws_msg; extern long ws_close_code; extern char *g_ca_file;
int net_init(const char*, const char*); int ws_connect(const char*); int ws_poll_message(int);
int ws_send_text(const char*, size_t); int ws_send_frame(int,const void*,size_t); void ws_close(void);
int main(int argc,char**argv){
  g_ca_file="cert.pem"; net_init("tok","key");
  if (ws_connect(argv[1])!=0){puts("connect FAIL");return 1;}
  puts("connected");
  int r; 
  r=ws_poll_message(3000); printf("r=%d msg=%s\n",r,ws_msg.data);
  ws_send_text("hello-from-asm",14);
  r=ws_poll_message(3000); printf("r=%d msg=%s\n",r,ws_msg.data);
  r=ws_poll_message(3000); printf("r=%d len=%zu head=%.5s (frag msg expects B*10 C*5 D*3)\n",r,ws_msg.len,ws_msg.data);
  ws_send_frame(10,"ping!",5); /* we already auto-ponged; this is extra */
  r=ws_poll_message(3000); printf("r=%d len=%zu\n",r,ws_msg.len);
  char *b=malloc(100000); memset(b,'x',100000); {char m[1000]; memset(m,0x79,1000); ws_send_text(m,1000);}
  r=ws_poll_message(5000); printf("r=%d len=%zu\n",r,ws_msg.len);
  ws_send_text(b,100000);
  r=ws_poll_message(5000); printf("r=%d len=%zu (expects 3000000)\n",r,ws_msg.len);
  ws_send_text(b,70000);
  r=ws_poll_message(3000); printf("r=%d closecode=%ld\n",r,ws_close_code);
  r=ws_poll_message(300); printf("timeout test r=%d\n",r);
  ws_close(); return 0;}
