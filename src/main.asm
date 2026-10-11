; =====================================================================
; main.asm - CaineASM Lite entry point: .env loading, configuration,
;            signal handling, then the gateway loop.
; =====================================================================
%include "defs.inc"

extern getenv, setenv, signal, calloc, free, memcpy, strndup, fopen, fread, fclose, puts
extern sb_init, sb_free, sb_append, sb_appends, sb_append_json_esc
extern parse_u64, c_strlen, ieq
extern net_init, settings_load, gateway_run, log_line
extern g_discord_token, g_groq_key, g_prefix, g_prefix_len, g_prefix_esc
extern g_owner_id, g_default_model, g_vision_model, g_max_history
extern g_ai_rate_max, g_ai_rate_window, g_api_base, g_groq_url, g_gateway_url
extern g_data_file, g_stop, g_default_persona, g_ca_file

section .rodata
s_version:   db "CaineASM Lite v1.0.0", 0
s_dotenv:    db ".env", 0
s_rb:        db "rb", 0
a_version1:  db "--version", 0
a_version2:  db "-v", 0

n_token:     db "DISCORD_TOKEN", 0
n_groq:      db "GROQ_API_KEY", 0
n_prefix:    db "BOT_PREFIX", 0
n_persona:   db "SYSTEM_PROMPT", 0
n_owner:     db "BOT_OWNER_ID", 0
n_maxhist:   db "MAX_HISTORY", 0
n_ratemax:   db "AI_RATE_MAX", 0
n_ratewin:   db "AI_RATE_WINDOW_SEC", 0
n_datafile:  db "DATA_FILE", 0
n_model:     db "DEFAULT_MODEL", 0
n_vmodel:    db "VISION_MODEL", 0
n_apibase:   db "DISCORD_API_BASE", 0
n_groqurl:   db "GROQ_API_URL", 0
n_gwurl:     db "DISCORD_GATEWAY_URL", 0
n_cafile:    db "CAINE_CA_FILE", 0

d_prefix:    db "Caine", 0
d_persona:   db "Kamu adalah AI asisten yang nyantai dan gaul. Jawab pake bahasa Indonesia slang yang natural, kayak ngobrol sama teman. Tetep informatif dan tepat tapi ga kaku.", 0
d_model:     db "openai/gpt-oss-120b", 0
d_vmodel:    db "qwen/qwen3.8-27b", 0
d_apibase:   db "https://discord.com/api/v10", 0
d_groqurl:   db "https://api.groq.com/openai/v1/chat/completions", 0
d_gwurl:     db "wss://gateway.discord.gg/?v=10&encoding=json", 0
d_datafile:  db "./caine_settings.txt", 0
s_export:    db "export "
m_needkeys:  db "❌ DISCORD_TOKEN and GROQ_API_KEY are required (see .env.example)", 0
m_start:     db "🚀 CaineASM Lite starting...", 0
m_bye:       db "🛑 Shutting down...", 0
m_nonet:     db "❌ libcurl initialisation failed", 0

section .text

; char *env_or(const char *name, const char *def)
env_or:
    push rbx
    mov rbx, rsi
    CALLC getenv
    test rax, rax
    jz .def
    cmp byte [rax], 0
    je .def
    pop rbx
    ret
.def:
    mov rax, rbx
    pop rbx
    ret

; long env_num(const char *name, long def)
env_num:
    ENTER 0
    mov r12, rsi
    CALLC getenv
    test rax, rax
    jz .def
    mov r13, rax
    mov rdi, rax
    call c_strlen
    mov rdi, r13
    mov rsi, rax
    call parse_u64
    test rdx, rdx
    jz .def
    LEAVE_RET
.def:
    mov rax, r12
    LEAVE_RET

; char *pad_dup(const char *s)  heap copy with zero padding (safe for short prefix compares)
pad_dup:
    ENTER 0
    mov r12, rdi
    call c_strlen
    mov r13, rax
    mov edi, 1
    lea rsi, [r13 + 64]
    CALLC calloc
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    CALLC memcpy
    mov rax, rbx
    LEAVE_RET

; void on_signal(int sig)
on_signal:
    mov qword [rel g_stop], 1
    ret

; (rax=ptr, rdx=len) trim_ws(p, n)  strip raw spaces, tabs, CR, LF on both ends
trim_ws:
.l1:
    test rsi, rsi
    jz .done
    movzx eax, byte [rdi]
    cmp al, ' '
    je .a
    cmp al, 9
    je .a
    cmp al, 13
    je .a
    cmp al, 10
    jne .l2
.a:
    inc rdi
    dec rsi
    jmp .l1
.l2:
    test rsi, rsi
    jz .done
    movzx eax, byte [rdi + rsi - 1]
    cmp al, ' '
    je .b
    cmp al, 9
    je .b
    cmp al, 13
    je .b
    cmp al, 10
    jne .done
.b:
    dec rsi
    jmp .l2
.done:
    mov rax, rdi
    mov rdx, rsi
    ret

; void dotenv_line(const char *p, size_t n)   KEY=VALUE, never overrides the real environment
dotenv_line:
    ENTER 0
    mov rax, rdi
    mov rdx, rsi
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz .d
    cmp byte [r12], '#'
    je .d
    ; optional "export "
    cmp r13, 7
    jbe .noexp
    mov rdi, r12
    mov rsi, 7
    lea rdx, [rel s_export]
    ; compare 7 bytes by hand (case-sensitive)
    xor ecx, ecx
.ex:
    cmp ecx, 7
    jae .isexp
    mov al, [r12 + rcx]
    cmp al, [rdx + rcx]
    jne .noexp
    inc ecx
    jmp .ex
.isexp:
    add r12, 7
    sub r13, 7
.noexp:
    ; find '='
    xor ebx, ebx
.eq:
    cmp rbx, r13
    jae .d
    cmp byte [r12 + rbx], '='
    je .haseq
    inc rbx
    jmp .eq
.haseq:
    mov rdi, r12
    mov rsi, rbx
    call trim_ws
    test rdx, rdx
    jz .d
    mov rdi, rax
    mov rsi, rdx
    CALLC strndup
    mov r14, rax                    ; key
    lea rdi, [r12 + rbx + 1]
    mov rsi, r13
    sub rsi, rbx
    dec rsi
    call trim_ws
    mov r15, rax                    ; value ptr
    mov r13, rdx                    ; value len
    ; quoted value?
    cmp r13, 2
    jb .unq
    mov al, [r15]
    cmp al, '"'
    je .q
    cmp al, "'"
    jne .unq
.q:
    cmp [r15 + r13 - 1], al
    jne .unq
    inc r15
    sub r13, 2
    jmp .setit
.unq:
    ; drop an inline " #comment"
    xor ecx, ecx
.cm:
    lea rax, [rcx + 1]
    cmp rax, r13
    jae .setit
    cmp byte [r15 + rcx], ' '
    jne .cmn
    cmp byte [r15 + rcx + 1], '#'
    jne .cmn
    mov rdi, r15
    mov rsi, rcx
    call trim_ws
    mov r15, rax
    mov r13, rdx
    jmp .setit
.cmn:
    inc rcx
    jmp .cm
.setit:
    mov rdi, r15
    mov rsi, r13
    CALLC strndup
    mov rbx, rax
    mov rdi, r14
    mov rsi, rbx
    xor edx, edx                    ; do not overwrite existing variables
    CALLC setenv
    mov rdi, r14
    CALLC free
    mov rdi, rbx
    CALLC free
.d:
    LEAVE_RET

; void load_dotenv(void)
load_dotenv:
    ENTER 4152                      ; [0] sbuf, [32] read chunk
    lea rdi, [rel s_dotenv]
    lea rsi, [rel s_rb]
    CALLC fopen
    test rax, rax
    jz .ret
    mov r12, rax
    lea rdi, [rsp]
    call sb_init
.rd:
    lea rdi, [rsp + 32]
    mov esi, 1
    mov edx, 4096
    mov rcx, r12
    CALLC fread
    test rax, rax
    jz .eof
    lea rdi, [rsp]
    lea rsi, [rsp + 32]
    mov rdx, rax
    call sb_append
    jmp .rd
.eof:
    mov rdi, r12
    CALLC fclose
    mov r13, [rsp]
    mov r14, r13
    add r14, [rsp + 8]
.line:
    cmp r13, r14
    jae .free
    mov rbx, r13
.nl:
    cmp rbx, r14
    jae .gotline
    cmp byte [rbx], 10
    je .gotline
    inc rbx
    jmp .nl
.gotline:
    mov rdi, r13
    mov rsi, rbx
    sub rsi, r13
    call dotenv_line
    lea r13, [rbx + 1]
    jmp .line
.free:
    lea rdi, [rsp]
    call sb_free
.ret:
    LEAVE_RET

; int main(int argc, char **argv)
global main
main:
    ENTER 32
    mov r12d, edi
    mov r13, rsi
    ; --version / -v
    mov ebx, 1
.args:
    cmp ebx, r12d
    jge .noargs
    mov rdi, [r13 + rbx * 8]
    call c_strlen
    mov rsi, rax
    mov rdi, [r13 + rbx * 8]
    lea rdx, [rel a_version1]
    call ieq
    test eax, eax
    jnz .ver
    mov rdi, [r13 + rbx * 8]
    call c_strlen
    mov rsi, rax
    mov rdi, [r13 + rbx * 8]
    lea rdx, [rel a_version2]
    call ieq
    test eax, eax
    jnz .ver
    inc ebx
    jmp .args
.ver:
    lea rdi, [rel s_version]
    CALLC puts
    xor eax, eax
    LEAVE_RET
.noargs:
    call load_dotenv

    ; ---- required secrets ----
    lea rdi, [rel n_token]
    lea rsi, [rel s_empty_main]
    call env_or
    mov [rel g_discord_token], rax
    lea rdi, [rel n_groq]
    lea rsi, [rel s_empty_main]
    call env_or
    mov [rel g_groq_key], rax
    mov rax, [rel g_discord_token]
    cmp byte [rax], 0
    je .nokeys
    mov rax, [rel g_groq_key]
    cmp byte [rax], 0
    je .nokeys

    ; ---- optional settings ----
    lea rdi, [rel n_prefix]
    lea rsi, [rel d_prefix]
    call env_or
    mov [rel g_prefix], rax
    mov rdi, rax
    call c_strlen
    mov [rel g_prefix_len], rax
    ; escaped prefix for text templates
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, [rel g_prefix]
    mov rdx, [rel g_prefix_len]
    call sb_append_json_esc
    mov rdi, [rsp]
    call pad_dup
    mov [rel g_prefix_esc], rax
    lea rdi, [rsp]
    call sb_free
    ; default persona, escaped once
    lea rdi, [rel g_default_persona]
    call sb_init
    lea rdi, [rel n_persona]
    lea rsi, [rel d_persona]
    call env_or
    mov r14, rax
    mov rdi, rax
    call c_strlen
    lea rdi, [rel g_default_persona]
    mov rsi, r14
    mov rdx, rax
    call sb_append_json_esc
    lea rdi, [rel n_owner]
    lea rsi, [rel s_empty_main]
    call env_or
    mov [rel g_owner_id], rax
    lea rdi, [rel n_model]
    lea rsi, [rel d_model]
    call env_or
    mov rdi, rax
    call pad_dup
    mov [rel g_default_model], rax
    lea rdi, [rel n_vmodel]
    lea rsi, [rel d_vmodel]
    call env_or
    mov rdi, rax
    call pad_dup
    mov [rel g_vision_model], rax
    lea rdi, [rel n_apibase]
    lea rsi, [rel d_apibase]
    call env_or
    mov [rel g_api_base], rax
    lea rdi, [rel n_groqurl]
    lea rsi, [rel d_groqurl]
    call env_or
    mov [rel g_groq_url], rax
    lea rdi, [rel n_gwurl]
    lea rsi, [rel d_gwurl]
    call env_or
    mov [rel g_gateway_url], rax
    lea rdi, [rel n_datafile]
    lea rsi, [rel d_datafile]
    call env_or
    mov [rel g_data_file], rax
    lea rdi, [rel n_cafile]
    lea rsi, [rel s_empty_main]
    call env_or
    cmp byte [rax], 0
    je .noca
    mov [rel g_ca_file], rax
.noca:
    lea rdi, [rel n_maxhist]
    mov esi, 30
    call env_num
    cmp rax, 5
    jae .mh1
    mov eax, 5
.mh1:
    cmp rax, 100
    jbe .mh2
    mov eax, 100
.mh2:
    mov [rel g_max_history], rax
    lea rdi, [rel n_ratemax]
    mov esi, 10
    call env_num
    test rax, rax
    jnz .rm1
    mov eax, 10
.rm1:
    cmp rax, 32
    jbe .rm2
    mov eax, 32
.rm2:
    mov [rel g_ai_rate_max], rax
    lea rdi, [rel n_ratewin]
    mov esi, 60
    call env_num
    test rax, rax
    jnz .rw1
    mov eax, 60
.rw1:
    imul rax, rax, 1000
    mov [rel g_ai_rate_window], rax

    ; ---- runtime ----
    mov rdi, [rel g_discord_token]
    mov rsi, [rel g_groq_key]
    call net_init
    test eax, eax
    jnz .nonet
    mov edi, SIGPIPE
    mov esi, SIG_IGN
    CALLC signal
    mov edi, SIGINT
    lea rsi, [rel on_signal]
    CALLC signal
    mov edi, SIGTERM
    lea rsi, [rel on_signal]
    CALLC signal
    call settings_load
    lea rdi, [rel m_start]
    call log_line
    call gateway_run
    lea rdi, [rel m_bye]
    call log_line
    xor eax, eax
    LEAVE_RET
.nokeys:
    lea rdi, [rel m_needkeys]
    call log_line
    mov eax, 1
    LEAVE_RET
.nonet:
    lea rdi, [rel m_nonet]
    call log_line
    mov eax, 1
    LEAVE_RET

section .rodata
s_empty_main: db 0
