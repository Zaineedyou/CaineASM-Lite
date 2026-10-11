#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

typedef struct { char *data; size_t len, cap; } sbuf;
typedef struct { const char *ptr; size_t len; long type; } jv;

void sb_init(sbuf*); void sb_free(sbuf*); void sb_reset(sbuf*);
void sb_reserve(sbuf*, size_t); void sb_append(sbuf*, const char*, size_t);
void sb_appends(sbuf*, const char*); void sb_putc(sbuf*, int);
void sb_append_u64(sbuf*, uint64_t); void sb_append_json_esc(sbuf*, const char*, size_t);
const char *mem_ifind(const char*, size_t, const char*, size_t);
int ieq(const char*, size_t, const char*);
typedef struct { uint64_t v, d; } pr;
pr parse_u64(const char*, size_t);
uint64_t now_ms(void); void sleep_ms(uint64_t);
typedef struct { const char *p; size_t n; } span;
span trim_span(const char*, size_t);
size_t b64_encode(const uint8_t*, size_t, char*);
size_t chunk_next(const char*, size_t, size_t);
size_t c_strlen(const char*);
const char *json_skip_ws(const char*, const char*);
const char *json_value(const char*, const char*, jv*);
int json_get(const char*, size_t, const char*, jv*);
int json_path(const char*, size_t, const char*, jv*);
const char *json_arr_next(const char*, const char*, jv*);
int json_true(const jv*);

static int fails = 0;
#define CHECK(c) do { if(!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while(0)

int main(void) {
    /* sbuf */
    sbuf sb; sb_init(&sb);
    CHECK(sb.len == 0 && sb.cap >= 256 && sb.data[0] == 0);
    sb_appends(&sb, "hello"); sb_putc(&sb, ' '); sb_append_u64(&sb, 0); sb_putc(&sb,' ');
    sb_append_u64(&sb, 18446744073709551615ULL); sb_putc(&sb,' '); sb_append_u64(&sb, 1234567890123ULL);
    CHECK(strcmp(sb.data, "hello 0 18446744073709551615 1234567890123") == 0);
    CHECK(sb.len == strlen(sb.data));
    sb_reset(&sb); CHECK(sb.len == 0 && sb.data[0] == 0);
    /* growth */
    for (int i = 0; i < 100000; i++) sb_putc(&sb, 'a' + (i % 26));
    CHECK(sb.len == 100000 && sb.data[99999] == 'a' + (99999 % 26) && sb.data[100000] == 0);
    sb_reset(&sb);
    /* json esc */
    const char raw[] = "a\"b\\c\nd\re\tf\x01g\x1f h/é😀";
    sb_append_json_esc(&sb, raw, sizeof raw - 1);
    CHECK(strcmp(sb.data, "a\\\"b\\\\c\\nd\\re\\tf\\u0001g\\u001f h/é😀") == 0);
    sb_free(&sb);
    /* mem_ifind */
    const char *h = "Hey CAINE how are you";
    CHECK(mem_ifind(h, strlen(h), "caine", 5) == h + 4);
    CHECK(mem_ifind(h, strlen(h), "you", 3) == h + 18);
    CHECK(mem_ifind(h, strlen(h), "youu", 4) == NULL);
    CHECK(mem_ifind(h, strlen(h), "", 0) == h);
    CHECK(mem_ifind("ab", 2, "abc", 3) == NULL);
    CHECK(mem_ifind("xxCa", 4, "Caine", 5) == NULL);
    CHECK(mem_ifind("Caine", 5, "caine", 5) != NULL);
    CHECK(mem_ifind("[x]", 3, "[X]", 3) != NULL);
    /* ieq */
    CHECK(ieq("ReSeT", 5, "reset") == 1);
    CHECK(ieq("resetx", 5, "reset") == 1);
    CHECK(ieq("resetx", 6, "reset") == 0);
    CHECK(ieq("rese", 4, "reset") == 0);
    CHECK(ieq("", 0, "") == 1);
    CHECK(ieq("a", 0, "") == 1);
    /* parse_u64 */
    pr r = parse_u64("45000x", 6); CHECK(r.v == 45000 && r.d == 5);
    r = parse_u64("x", 1); CHECK(r.v == 0 && r.d == 0);
    r = parse_u64("123", 2); CHECK(r.v == 12 && r.d == 2);
    r = parse_u64("9223372036854775808", 19); CHECK(r.v == 9223372036854775808ULL);
    /* now_ms/sleep_ms */
    uint64_t t0 = now_ms(); sleep_ms(120); uint64_t t1 = now_ms();
    CHECK(t1 - t0 >= 115 && t1 - t0 < 400);
    /* trim_span */
    { span s = trim_span("  \\n hi there \\t\\r ", strlen("  \\n hi there \\t\\r ")); CHECK(s.n == 8 && memcmp(s.p, "hi there", 8) == 0); }
    { span s = trim_span("a\\\\n", 4); CHECK(s.n == 4); }            /* a\\n : literal backslash + n kept */
    { span s = trim_span("a\\\\\\n", 5); CHECK(s.n == 3); }           /* a\\\n : escaped backslash + newline -> a\\ */
    { span s = trim_span("   ", 3); CHECK(s.n == 0); }
    { span s = trim_span("", 0); CHECK(s.n == 0); }
    { span s = trim_span("\\n", 2); CHECK(s.n == 0); }
    { span s = trim_span("tn", 2); CHECK(s.n == 2); }
    { span s = trim_span("\\", 1); CHECK(s.n == 1); }
    { span s = trim_span("x\nfoo\r\n", 7); CHECK(s.n == 5 && memcmp(s.p,"x\nfoo",5)==0); }
    /* b64 */
    {
        const char *tests[] = {"", "f", "fo", "foo", "foba", "fobar", "0123456789abcdef"};
        const char *exp[] = {"", "Zg==", "Zm8=", "Zm9v", "Zm9iYQ==", "Zm9iYXI=", "MDEyMzQ1Njc4OWFiY2RlZg=="};
        for (int i = 0; i < 7; i++) {
            char out[64]; size_t n = b64_encode((const uint8_t*)tests[i], strlen(tests[i]), out);
            CHECK(n == strlen(exp[i])); CHECK(strcmp(out, exp[i]) == 0);
        }
        uint8_t bin[16]; for (int i=0;i<16;i++) bin[i]=(uint8_t)(i*17+3);
        char out[64]; size_t n = b64_encode(bin, 16, out); CHECK(n == 24);
        FILE *f = popen("python3 -c \"import base64;print(base64.b64encode(bytes((i*17+3)&255 for i in range(16))).decode())\"", "r");
        char buf[64]={0}; fgets(buf, 64, f); pclose(f); buf[strcspn(buf, "\n")] = 0;
        CHECK(strcmp(buf, out) == 0);
    }
    /* chunk_next */
    {
        char big[5000]; memset(big, 'a', sizeof big);
        CHECK(chunk_next(big, 100, 1900) == 100);
        CHECK(chunk_next(big, 5000, 1900) == 1900);
        /* newline boundary preferred */
        char t[3000]; memset(t, 'x', sizeof t);
        memcpy(t + 1500, "\\n", 2);               /* boundary after 1502 */
        memcpy(t + 1890, "\\n", 2);
        CHECK(chunk_next(t, 3000, 1900) == 1892);
        /* never split an escape: place a backslash escape across the max */
        memset(t, 'x', sizeof t); memcpy(t + 1899, "\\\"", 2); /* bytes 1899,1900 */
        CHECK(chunk_next(t, 3000, 1900) == 1899);
        /* \uXXXX not split */
        memset(t, 'x', sizeof t); memcpy(t + 1897, "\\u00e9", 6);
        CHECK(chunk_next(t, 3000, 1900) == 1897);
        /* surrogate pair not split: 12 bytes starting at 1895 */
        memset(t, 'x', sizeof t); memcpy(t + 1895, "\\ud83d\\ude00", 12);
        CHECK(chunk_next(t, 3000, 1900) == 1895);
        /* a surrogate pair fully inside is kept together */
        memset(t, 'x', sizeof t); memcpy(t + 1880, "\\ud83d\\ude00", 12);
        CHECK(chunk_next(t, 3000, 1900) == 1900);
        /* UTF-8 not split: 4-byte emoji straddling max */
        memset(t, 'x', sizeof t); memcpy(t + 1898, "\xF0\x9F\x98\x80", 4);
        CHECK(chunk_next(t, 3000, 1900) == 1898);
        memset(t, 'x', sizeof t); memcpy(t + 1897, "\xE2\x9C\x85", 3);   /* fits exactly to 1900 */
        CHECK(chunk_next(t, 3000, 1900) == 1900);
        memset(t, 'x', sizeof t); memcpy(t + 1898, "\xE2\x9C\x85", 3);
        CHECK(chunk_next(t, 3000, 1900) == 1898);
        /* early newline (<25%) is ignored */
        memset(t, 'x', sizeof t); memcpy(t + 100, "\\n", 2);
        CHECK(chunk_next(t, 3000, 1900) == 1900);
        /* escaped backslash followed by n is NOT a newline: \\n  */
        memset(t, 'x', sizeof t); memcpy(t + 1500, "\\\\n", 3);
        CHECK(chunk_next(t, 3000, 1900) == 1900);
    }
    /* ---------------- JSON ---------------- */
    {
        const char *js = " {\"op\":0,\"s\" : 42 ,\"t\":\"MESSAGE_CREATE\",\"d\":{\"id\":\"123\",\"content\":\"hi \\\"there\\\" \\\\ \\n x\",\"author\":{\"id\":\"9\",\"username\":\"u}[{\",\"bot\":false},\"mentions\":[{\"id\":\"1\"},{\"id\":\"2\",\"x\":[1,2,{\"a\":\"]\"}]}],\"nick\":null,\"f\":-1.5e+3,\"ok\":true},\"x\":\"y\"} ";
        size_t n = strlen(js); jv v;
        CHECK(json_get(js, n, "op", &v) && v.type == 'd' && v.len == 1 && v.ptr[0] == '0');
        CHECK(json_get(js, n, "s", &v) && v.type == 'd' && v.len == 2 && memcmp(v.ptr, "42", 2) == 0);
        CHECK(json_get(js, n, "t", &v) && v.type == 's' && v.len == 14 && memcmp(v.ptr, "MESSAGE_CREATE", 14) == 0);
        CHECK(json_get(js, n, "x", &v) && v.type == 's' && v.len == 1 && v.ptr[0] == 'y');
        CHECK(!json_get(js, n, "nope", &v));
        CHECK(!json_get(js, n, "o", &v));          /* "op" must not match "o" */
        CHECK(!json_get(js, n, "opp", &v));
        CHECK(json_get(js, n, "d", &v) && v.type == 'o');
        jv d = v;
        CHECK(json_get(d.ptr, d.len, "id", &v) && v.len == 3 && memcmp(v.ptr, "123", 3) == 0);
        CHECK(json_get(d.ptr, d.len, "content", &v) && v.type == 's');
        CHECK(v.len == strlen("hi \\\"there\\\" \\\\ \\n x") && memcmp(v.ptr, "hi \\\"there\\\" \\\\ \\n x", v.len) == 0);
        CHECK(json_path(js, n, "d.author.id", &v) && v.len == 1 && v.ptr[0] == '9');
        CHECK(json_path(js, n, "d.author.username", &v) && v.len == 4 && memcmp(v.ptr, "u}[{", 4) == 0);
        CHECK(json_path(js, n, "d.author.bot", &v) && v.type == 'b' && !json_true(&v));
        CHECK(json_path(js, n, "d.ok", &v) && v.type == 'b' && json_true(&v));
        CHECK(json_path(js, n, "d.nick", &v) && v.type == 'n');
        CHECK(json_path(js, n, "d.f", &v) && v.type == 'd' && v.len == 7 && memcmp(v.ptr, "-1.5e+3", 7) == 0);
        CHECK(!json_path(js, n, "d.author.id.zz", &v));
        CHECK(!json_path(js, n, "d.nick.id", &v));
        CHECK(!json_path(js, n, "q.author", &v));
        CHECK(json_path(js, n, "op", &v) && v.type == 'd');
        /* arrays */
        CHECK(json_path(js, n, "d.mentions", &v) && v.type == 'a');
        const char *cur = v.ptr + 1, *end = v.ptr + v.len; jv e; int cnt = 0; char ids[8] = {0};
        while ((cur = json_arr_next(cur, end, &e)) != NULL) {
            CHECK(e.type == 'o'); jv id; CHECK(json_get(e.ptr, e.len, "id", &id)); ids[cnt++] = id.ptr[0];
        }
        CHECK(cnt == 2 && strcmp(ids, "12") == 0);
        /* array of strings / mixed */
        const char *arr = "[ \"a\" , \"b\\\"c\",12, null,true , [1,[2]] ]";
        cur = arr + 1; end = arr + strlen(arr); cnt = 0; char types[16] = {0};
        while ((cur = json_arr_next(cur, end, &e)) != NULL) types[cnt++] = (char)e.type;
        CHECK(cnt == 6 && strcmp(types, "ssdnba") == 0);
        const char *empty = "[ ]"; CHECK(json_arr_next(empty + 1, empty + 3, &e) == NULL);
        /* malformed input must not crash */
        const char *bad[] = {"", "{", "{\"a\"", "{\"a\":", "{\"a\":\"unterminated", "{\"a\":{\"b\":[}", "[", "tru", "{\"a\":nul}", "{\"a\":-", "{1:2}", "{\"a\" 1}"};
        for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) { jv q; json_get(bad[i], strlen(bad[i]), "a", &q); json_path(bad[i], strlen(bad[i]), "a.b", &q); }
        CHECK(json_get("{\"a\":-}", 7, "a", &v) == 1);  /* lenient number scan */
        /* top-level key after a huge nested value */
        sbuf big; sb_init(&big); sb_appends(&big, "{\"d\":{\"arr\":[");
        for (int i = 0; i < 20000; i++) sb_appends(&big, "{\"k\":\"v}\\\"]\",\"n\":[1,2,3]},");
        sb_appends(&big, "0]},\"op\":10}");
        CHECK(json_get(big.data, big.len, "op", &v) && v.len == 2 && memcmp(v.ptr, "10", 2) == 0);
        sb_free(&big);
    }
    printf(fails ? "SOME TESTS FAILED (%d)\n" : "ALL util/json TESTS PASSED\n", fails);
    return fails != 0;
}
