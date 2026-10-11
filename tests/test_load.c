#include <stdio.h>
#include <string.h>
typedef struct { char *data; size_t len, cap; } sbuf;
extern char *g_default_model, *g_data_file; extern long g_max_history;
extern sbuf g_default_persona;
void sb_init(sbuf*); void sb_appends(sbuf*,const char*);
const char*settings_model(const char*); long settings_maxhist(const char*); void settings_append_persona(sbuf*,const char*); void settings_load(void);
int main(){ g_default_model="def"; g_max_history=30; g_data_file="/tmp/caine_test_settings.txt"; sb_init(&g_default_persona); sb_appends(&g_default_persona,"DEF");
 settings_load(); sbuf p; sb_init(&p); settings_append_persona(&p,"42");
 printf("%s %ld [%s] | %s %ld\n",settings_model("42"),settings_maxhist("42"),p.data,settings_model("77"),settings_maxhist("77")); return 0;}
