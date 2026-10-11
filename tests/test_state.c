#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
typedef struct { char *data; size_t len, cap; } sbuf;
extern char *g_default_model, *g_data_file; extern long g_max_history, g_ai_rate_max, g_ai_rate_window;
extern sbuf g_default_persona;
void sb_init(sbuf*); void sb_free(sbuf*); void sb_appends(sbuf*,const char*);
int rl_fast(const char*,size_t); int rl_ai(const char*,size_t);
int model_lookup(const char*,size_t); const char*model_id_of(int);
const char*settings_model(const char*); long settings_maxhist(const char*);
void settings_append_persona(sbuf*,const char*);
void settings_set_model(const char*,long); void settings_set_maxhist(const char*,long); void settings_set_persona(const char*,const char*,size_t);
void settings_load(void);
void hist_add(const char*,long,const char*,size_t,size_t); void hist_snapshot(const char*,size_t,sbuf*); void hist_clear(const char*);
void sleep_ms(unsigned long);
static int fails=0;
#define CHECK(c) do{ if(!(c)){printf("FAIL line %d: %s\n",__LINE__,#c);fails++;} }while(0)
int main(void){
  g_default_model="openai/gpt-oss-120b"; g_max_history=30; g_ai_rate_max=3; g_ai_rate_window=500;
  g_data_file="/tmp/caine_test_settings.txt"; remove(g_data_file);
  sb_init(&g_default_persona); sb_appends(&g_default_persona,"DEFAULT PERSONA");
  /* fast limiter */
  CHECK(rl_fast("111",3)==0); CHECK(rl_fast("111",3)==1); CHECK(rl_fast("222",3)==0);
  sleep_ms(2100); CHECK(rl_fast("111",3)==0);
  /* ai limiter: 3 per 500ms */
  CHECK(rl_ai("u1",2)==0); CHECK(rl_ai("u1",2)==0); CHECK(rl_ai("u1",2)==0); CHECK(rl_ai("u1",2)==1);
  CHECK(rl_ai("u2",2)==0);
  sleep_ms(600); CHECK(rl_ai("u1",2)==0);
  /* many users -> eviction doesn't crash */
  for(int i=0;i<2000;i++){ char b[24]; sprintf(b,"user%d",i); rl_fast(b,strlen(b)); rl_ai(b,strlen(b)); }
  /* model lookup */
  CHECK(model_lookup("GPT120B",7)==1); CHECK(model_lookup("gpt20b",6)==2); CHECK(model_lookup("qwen27b",7)==3);
  CHECK(model_lookup("llama70b",8)==0); CHECK(model_lookup("gpt120",6)==0);
  CHECK(strcmp(model_id_of(3),"qwen/qwen3.8-27b")==0);
  /* settings */
  CHECK(strcmp(settings_model("42"),"openai/gpt-oss-120b")==0); CHECK(settings_maxhist("42")==30);
  CHECK(strcmp(settings_model(""),"openai/gpt-oss-120b")==0);
  settings_set_model("42",2); settings_set_maxhist("42",50); settings_set_persona("42","Kamu \\\"bajak laut\\\"",19);
  settings_set_model("77",3);
  CHECK(strcmp(settings_model("42"),"openai/gpt-oss-20b")==0); CHECK(settings_maxhist("42")==50);
  CHECK(strcmp(settings_model("77"),"qwen/qwen3.8-27b")==0); CHECK(settings_maxhist("77")==30);
  sbuf p; sb_init(&p); settings_append_persona(&p,"42"); CHECK(strcmp(p.data,"Kamu \\\"bajak laut\\\"")==0);
  p.len=0; p.data[0]=0; settings_append_persona(&p,"77"); CHECK(strcmp(p.data,"DEFAULT PERSONA")==0);
  settings_set_persona("42","Persona baru",12); p.len=0; p.data[0]=0; settings_append_persona(&p,"42"); CHECK(strcmp(p.data,"Persona baru")==0);
  settings_set_persona("",  "x",1); /* DM: ignored, no crash */
  FILE*f=fopen(g_data_file,"r"); char buf[512]={0}; fread(buf,1,511,f); fclose(f); printf("--- file ---\n%s------------\n",buf);
  /* reload in same process: clear by loading over (entries exist) - verify file content semantic instead */
  CHECK(strstr(buf,"42 2 50 Persona baru\n")!=NULL); CHECK(strstr(buf,"77 3 0 \n")!=NULL);
  /* history */
  sbuf h; sb_init(&h);
  hist_snapshot("k1",10,&h); CHECK(h.len==0);
  hist_add("k1",0,"halo",4,4); hist_add("k1",1,"hai juga",8,4); hist_add("k1",0,"u2",2,4); hist_add("k1",1,"a2",2,4);
  hist_snapshot("k1",10,&h);
  CHECK(strcmp(h.data,"{\"role\":\"user\",\"content\":\"halo\"},{\"role\":\"assistant\",\"content\":\"hai juga\"},{\"role\":\"user\",\"content\":\"u2\"},{\"role\":\"assistant\",\"content\":\"a2\"},")==0);
  hist_add("k1",0,"u3",2,4); h.len=0;h.data[0]=0; hist_snapshot("k1",10,&h);   /* limit 4 -> oldest dropped */
  CHECK(strstr(h.data,"halo")==NULL && strstr(h.data,"u3")!=NULL);
  h.len=0;h.data[0]=0; hist_snapshot("k1",2,&h);  /* only last 2 */
  CHECK(strstr(h.data,"a2")!=NULL && strstr(h.data,"u3")!=NULL && strstr(h.data,"u2")==NULL);
  hist_clear("k1"); h.len=0;h.data[0]=0; hist_snapshot("k1",10,&h); CHECK(h.len==0);
  hist_add("k1",0,"again",5,4); h.len=0;h.data[0]=0; hist_snapshot("k1",10,&h); CHECK(strstr(h.data,"again")!=NULL);
  /* ring wrap + long content cap + many keys */
  for(int i=0;i<1000;i++){ char c[16]; sprintf(c,"m%d",i); hist_add("wrap",i&1,c,strlen(c),200); }
  h.len=0;h.data[0]=0; hist_snapshot("wrap",500,&h); CHECK(strstr(h.data,"m999")!=NULL && strstr(h.data,"m799\"")==NULL && strstr(h.data,"m800\"")!=NULL);
  char *big=malloc(20000); memset(big,'x',20000); hist_add("big",0,big,20000,10); h.len=0;h.data[0]=0; hist_snapshot("big",10,&h); CHECK(h.len<4100);
  for(int i=0;i<500;i++){ char k[24]; sprintf(k,"server-%d",i); hist_add(k,0,"z",1,10); }
  hist_add("keep",0,"z",1,10);
  /* load test: new process view -> run settings_load on a fresh file */
  sb_free(&h); sb_free(&p);
  printf(fails?"STATE TESTS FAILED %d\n":"ALL state TESTS PASSED\n",fails); return fails!=0; }
