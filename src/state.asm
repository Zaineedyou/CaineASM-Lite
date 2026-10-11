; =====================================================================
; state.asm - configuration globals, rate limiters, per-guild settings
;             (persisted to a text file) and in-memory chat history.
; All shared tables are guarded by one mutex (workers run in threads).
; =====================================================================
%include "defs.inc"

extern pthread_mutex_lock, pthread_mutex_unlock
extern malloc, free, memcpy, memcmp, memset, fopen, fread, fwrite, fclose, rename, write
extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_putc, sb_append_u64
extern now_ms, c_strlen, ieq, parse_u64, chunk_next

%define USERS     512
%define U_SIZE    304
%define U_LAST    24
%define U_HEAD    32
%define U_COUNT   40
%define U_RING    48

%define GUILDS    256
%define G_SIZE    56
%define G_MODEL   24
%define G_HIST    32
%define G_PPTR    40
%define G_PLEN    48

%define HKEYS     128
%define HK_SIZE   80
%define HK_LAST   48
%define HK_COUNT  56
%define HK_HEAD   64
%define HK_ENTS   72
%define HCAP      200
%define HE_SIZE   24
%define HIST_ENTRY_MAX 4000

section .rodata
alias1: db "gpt120b", 0
alias2: db "gpt20b", 0
alias3: db "qwen27b", 0
mid1:   db "openai/gpt-oss-120b", 0
mid2:   db "openai/gpt-oss-20b", 0
mid3:   db "qwen/qwen3.8-27b", 0
section .data
align 8
model_aliases: dq alias1, alias2, alias3
model_ids:     dq mid1, mid2, mid3
section .rodata
global model_list_text
model_list_text: db "`gpt120b` → openai/gpt-oss-120b\n`gpt20b` → openai/gpt-oss-20b\n`qwen27b` → qwen/qwen3.8-27b", 0
s_tmp_suffix:  db ".tmp", 0
s_wb:          db "wb", 0
s_rb:          db "rb", 0
s_role_user:   db '{"role":"user","content":"', 0
s_role_asst:   db '{"role":"assistant","content":"', 0
s_obj_end:     db '"},', 0
s_nl:          db 10

section .bss
alignb 16
global g_mutex
g_mutex:        resb 64
; ---- configuration (filled by main) ----
global g_discord_token, g_groq_key, g_prefix, g_prefix_len, g_prefix_esc
global g_owner_id, g_default_model, g_vision_model, g_max_history
global g_ai_rate_max, g_ai_rate_window, g_api_base, g_groq_url, g_gateway_url
global g_data_file, g_bot_id, g_stop, g_active, g_default_persona
g_discord_token:   resq 1
g_groq_key:        resq 1
g_prefix:          resq 1
g_prefix_len:      resq 1
g_prefix_esc:      resq 1            ; JSON-escaped prefix (cstr)
g_owner_id:        resq 1
g_default_model:   resq 1
g_vision_model:    resq 1
g_max_history:     resq 1
g_ai_rate_max:     resq 1
g_ai_rate_window:  resq 1            ; ms
g_api_base:        resq 1
g_groq_url:        resq 1
g_gateway_url:     resq 1
g_data_file:       resq 1
g_stop:            resq 1
g_active:          resq 1
g_default_persona: resb 24           ; sbuf (JSON-escaped text)
g_bot_id:          resb 32
user_tab:          resb USERS * U_SIZE
guild_tab:         resb GUILDS * G_SIZE
hist_tab:          resb HKEYS * HK_SIZE

section .text

global state_lock, state_unlock
state_lock:
    push rbx
    lea rdi, [rel g_mutex]
    CALLC pthread_mutex_lock
    pop rbx
    ret
state_unlock:
    push rbx
    lea rdi, [rel g_mutex]
    CALLC pthread_mutex_unlock
    pop rbx
    ret

; ---------------------------------------------------------------------
; void log_line(const char *cstr)   one write() per line (thread friendly)
; ---------------------------------------------------------------------
global log_line
log_line:
    ENTER 0
    mov r12, rdi
    mov rdi, r12
    call c_strlen
    mov r13, rax
    sub rsp, 16
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r12
    mov rdx, r13
    call sb_append
    lea rdi, [rsp]
    mov esi, 10
    call sb_putc
    mov edi, STDOUT
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    CALLC write
    lea rdi, [rsp]
    call sb_free
    add rsp, 16
    LEAVE_RET

; void log_sb(sbuf *sb)  prints the buffer + newline and frees it
global log_sb
log_sb:
    ENTER 0
    mov rbx, rdi
    mov rdi, rbx
    mov esi, 10
    call sb_putc
    mov edi, STDOUT
    mov rsi, [rbx + SB_DATA]
    mov rdx, [rbx + SB_LEN]
    CALLC write
    mov rdi, rbx
    call sb_free
    LEAVE_RET

; =====================================================================
; Rate limiting
; =====================================================================

; user_find(id, len) -> entry*   (mutex must be held)
user_find:
    ENTER 32
    mov r12, rdi
    mov r13, rsi
    cmp r13, 23
    jbe .lenok
    mov r13d, 23
.lenok:
    lea r14, [rel user_tab]
    xor r15d, r15d                  ; index
    xor ebx, ebx                    ; first empty (NULL)
    xor ecx, ecx                    ; oldest entry
    mov qword [rsp], 0
.scan:
    cmp r15d, USERS
    jae .create
    imul rax, r15, U_SIZE
    lea rax, [r14 + rax]
    cmp byte [rax], 0
    je .empty
    cmp byte [rax + r13], 0
    jne .next
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    CALLC memcmp
    mov rcx, [rsp + 8]
    test eax, eax
    jnz .notsame
    mov rax, rcx
    LEAVE_RET
.notsame:
    mov rax, rcx
    jmp .next
.empty:
    test rbx, rbx
    jnz .next
    mov rbx, rax
    jmp .next
.next:
    ; track the oldest used entry (smallest last_ms)
    cmp byte [rax], 0
    je .adv
    mov rcx, [rsp]
    test rcx, rcx
    jz .setold
    mov rdx, [rax + U_LAST]
    cmp rdx, [rcx + U_LAST]
    jae .adv
.setold:
    mov [rsp], rax
.adv:
    inc r15d
    jmp .scan
.create:
    test rbx, rbx
    jnz .have
    mov rbx, [rsp]
.have:
    mov rdi, rbx
    xor esi, esi
    mov edx, U_SIZE
    CALLC memset
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    CALLC memcpy
    mov rax, rbx
    LEAVE_RET

; int rl_fast(const char *id, size_t len)  1 = message too soon after the last one (<2s)
global rl_fast
rl_fast:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call state_lock
    mov rdi, r12
    mov rsi, r13
    call user_find
    mov rbx, rax
    call now_ms
    xor r14d, r14d
    mov rcx, [rbx + U_LAST]
    test rcx, rcx
    jz .set
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, 2000
    jae .set
    mov r14d, 1
    jmp .done
.set:
    mov [rbx + U_LAST], rax
.done:
    call state_unlock
    mov eax, r14d
    LEAVE_RET

; int rl_ai(const char *id, size_t len)  1 = AI quota exceeded
global rl_ai
rl_ai:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call state_lock
    mov rdi, r12
    mov rsi, r13
    call user_find
    mov rbx, rax
    call now_ms
    mov r14, rax                    ; now
    mov r15, rax
    sub r15, [rel g_ai_rate_window] ; window start
.drop:
    mov rcx, [rbx + U_COUNT]
    test rcx, rcx
    jz .check
    mov rdx, [rbx + U_HEAD]
    mov rax, [rbx + U_RING + rdx * 8]
    cmp rax, r15
    jg .check
    inc rdx
    and rdx, 31
    mov [rbx + U_HEAD], rdx
    dec qword [rbx + U_COUNT]
    jmp .drop
.check:
    mov rcx, [rbx + U_COUNT]
    cmp rcx, [rel g_ai_rate_max]
    jae .limited
    mov rdx, [rbx + U_HEAD]
    add rdx, rcx
    and rdx, 31
    mov [rbx + U_RING + rdx * 8], r14
    inc qword [rbx + U_COUNT]
    xor r12d, r12d
    jmp .out
.limited:
    mov r12d, 1
.out:
    call state_unlock
    mov eax, r12d
    LEAVE_RET

; =====================================================================
; Per-guild settings
; =====================================================================

; guild_find(id cstr, create) -> entry* or NULL   (mutex held)
guild_find:
    ENTER 32
    mov r12, rdi
    mov r13d, esi
    cmp byte [r12], 0
    je .none                        ; DMs have no guild settings
    mov rdi, r12
    call c_strlen
    mov r14, rax
    cmp r14, 23
    ja .none
    lea r15, [rel guild_tab]
    xor ebx, ebx                    ; index
    mov qword [rsp], 0              ; first empty
.scan:
    cmp ebx, GUILDS
    jae .notfound
    imul rax, rbx, G_SIZE
    lea rax, [r15 + rax]
    cmp byte [rax], 0
    je .empty
    cmp byte [rax + r14], 0
    jne .adv
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r14
    CALLC memcmp
    test eax, eax
    jnz .adv
    mov rax, [rsp + 8]
    LEAVE_RET
.empty:
    cmp qword [rsp], 0
    jne .adv
    mov [rsp], rax
.adv:
    inc ebx
    jmp .scan
.notfound:
    test r13d, r13d
    jz .none
    mov rbx, [rsp]
    test rbx, rbx
    jz .none
    mov rdi, rbx
    xor esi, esi
    mov edx, G_SIZE
    CALLC memset
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    CALLC memcpy
    mov rax, rbx
    LEAVE_RET
.none:
    xor eax, eax
    LEAVE_RET

; int model_lookup(const char *p, size_t n) -> 1..3 or 0
global model_lookup
model_lookup:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
.l:
    cmp ebx, 3
    jae .no
    mov rdi, r12
    mov rsi, r13
    lea rax, [rel model_aliases]
    mov rdx, [rax + rbx * 8]
    call ieq
    test eax, eax
    jnz .yes
    inc ebx
    jmp .l
.yes:
    lea eax, [rbx + 1]
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; const char *model_alias_of(int idx)  / model_id_of(int idx)  (1..3)
global model_alias_of, model_id_of
model_alias_of:
    lea rax, [rel model_aliases]
    mov rax, [rax + rdi * 8 - 8]
    ret
model_id_of:
    lea rax, [rel model_ids]
    mov rax, [rax + rdi * 8 - 8]
    ret

; const char *settings_model(const char *guild)
global settings_model
settings_model:
    ENTER 0
    mov r12, rdi
    call state_lock
    mov rdi, r12
    xor esi, esi
    call guild_find
    xor r13d, r13d
    test rax, rax
    jz .u
    mov r13, [rax + G_MODEL]
.u:
    call state_unlock
    test r13, r13
    jz .def
    cmp r13, 3
    ja .def
    mov rdi, r13
    call model_id_of
    LEAVE_RET
.def:
    mov rax, [rel g_default_model]
    LEAVE_RET

; long settings_maxhist(const char *guild)
global settings_maxhist
settings_maxhist:
    ENTER 0
    mov r12, rdi
    call state_lock
    mov rdi, r12
    xor esi, esi
    call guild_find
    xor r13d, r13d
    test rax, rax
    jz .u
    mov r13, [rax + G_HIST]
.u:
    call state_unlock
    test r13, r13
    jnz .ret
    mov r13, [rel g_max_history]
.ret:
    mov rax, r13
    LEAVE_RET

; void settings_append_persona(sbuf *sb, const char *guild)
global settings_append_persona
settings_append_persona:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    call state_lock
    mov rdi, r12
    xor esi, esi
    call guild_find
    test rax, rax
    jz .def
    cmp qword [rax + G_PLEN], 0
    je .def
    mov rdi, rbx
    mov rsi, [rax + G_PPTR]
    mov rdx, [rax + G_PLEN]
    call sb_append
    jmp .un
.def:
    mov rdi, rbx
    mov rsi, [rel g_default_persona + SB_DATA]
    mov rdx, [rel g_default_persona + SB_LEN]
    call sb_append
.un:
    call state_unlock
    LEAVE_RET

; settings_save() - rewrite the data file (mutex held)
settings_save:
    ENTER 64                        ; [0] sbuf body, [24] sbuf path
    mov rax, [rel g_data_file]
    test rax, rax
    jz .ret
    cmp byte [rax], 0
    je .ret
    lea rdi, [rsp]
    call sb_init
    lea r14, [rel guild_tab]
    xor ebx, ebx
.l:
    cmp ebx, GUILDS
    jae .write
    imul rax, rbx, G_SIZE
    lea r12, [r14 + rax]
    inc ebx
    cmp byte [r12], 0
    je .l
    mov rax, [r12 + G_MODEL]
    or rax, [r12 + G_HIST]
    or rax, [r12 + G_PLEN]
    jz .l
    lea rdi, [rsp]
    mov rsi, r12
    call sb_appends
    lea rdi, [rsp]
    mov esi, ' '
    call sb_putc
    lea rdi, [rsp]
    mov rsi, [r12 + G_MODEL]
    call sb_append_u64
    lea rdi, [rsp]
    mov esi, ' '
    call sb_putc
    lea rdi, [rsp]
    mov rsi, [r12 + G_HIST]
    call sb_append_u64
    lea rdi, [rsp]
    mov esi, ' '
    call sb_putc
    cmp qword [r12 + G_PLEN], 0
    je .eol
    lea rdi, [rsp]
    mov rsi, [r12 + G_PPTR]
    mov rdx, [r12 + G_PLEN]
    call sb_append
.eol:
    lea rdi, [rsp]
    mov esi, 10
    call sb_putc
    jmp .l
.write:
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp + 24]
    mov rsi, [rel g_data_file]
    call sb_appends
    lea rdi, [rsp + 24]
    lea rsi, [rel s_tmp_suffix]
    call sb_appends
    mov rdi, [rsp + 24]
    lea rsi, [rel s_wb]
    CALLC fopen
    test rax, rax
    jz .fail
    mov r12, rax
    mov rdi, [rsp]
    mov esi, 1
    mov rdx, [rsp + 8]
    mov rcx, r12
    CALLC fwrite
    mov rdi, r12
    CALLC fclose
    mov rdi, [rsp + 24]
    mov rsi, [rel g_data_file]
    CALLC rename
.fail:
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
.ret:
    LEAVE_RET

; settings_set_model(guild, idx) / settings_set_maxhist(guild, n) / settings_set_persona(guild, p, n)
global settings_set_model, settings_set_maxhist, settings_set_persona
settings_set_model:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call state_lock
    mov rdi, r12
    mov esi, 1
    call guild_find
    test rax, rax
    jz .u
    mov [rax + G_MODEL], r13
    call settings_save
.u:
    call state_unlock
    LEAVE_RET
settings_set_maxhist:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call state_lock
    mov rdi, r12
    mov esi, 1
    call guild_find
    test rax, rax
    jz .u
    mov [rax + G_HIST], r13
    call settings_save
.u:
    call state_unlock
    LEAVE_RET
settings_set_persona:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rdi, [r14 + 1]
    CALLC malloc
    mov r15, rax
    test r15, r15
    jz .done
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    test rdx, rdx
    jz .nc
    CALLC memcpy
.nc:
    mov byte [r15 + r14], 0
    call state_lock
    mov rdi, r12
    mov esi, 1
    call guild_find
    test rax, rax
    jz .nog
    mov rbx, rax
    mov rdi, [rbx + G_PPTR]
    CALLC free
    mov [rbx + G_PPTR], r15
    mov [rbx + G_PLEN], r14
    call settings_save
    call state_unlock
    jmp .done
.nog:
    call state_unlock
    mov rdi, r15
    CALLC free
.done:
    LEAVE_RET

; void settings_load(void)   parse lines: "<guild> <model> <maxhist> <persona>"
global settings_load
settings_load:
    ENTER 4176                      ; [0] sbuf, [32..4127] read chunk, [4128] id, [4160] end, [4168] maxhist
    mov rax, [rel g_data_file]
    test rax, rax
    jz .ret
    cmp byte [rax], 0
    je .ret
    mov rdi, rax
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
    mov r13, [rsp]                  ; cursor
    mov r14, r13
    add r14, [rsp + 8]              ; end
.line:
    cmp r13, r14
    jae .free
    ; ---- guild id ----
    mov rbx, r13
.idl:
    cmp rbx, r14
    jae .skipline
    movzx eax, byte [rbx]
    cmp al, ' '
    je .gotid
    cmp al, 10
    je .skipline
    inc rbx
    jmp .idl
.gotid:
    mov r15, rbx
    sub r15, r13                    ; id length
    cmp r15, 23
    ja .skipline
    ; copy id to a temp cstr on the stack ([rsp+8..31])
    lea rdi, [rsp + 4128]
    mov rsi, r13
    mov rdx, r15
    test rdx, rdx
    jz .noidcopy
    CALLC memcpy
.noidcopy:
    mov byte [rsp + 4128 + r15], 0
    inc rbx                         ; past space
    ; ---- model ----
    mov rdi, rbx
    mov rsi, r14
    sub rsi, rdi
    call parse_u64
    mov r12, rax                    ; model
    add rbx, rdx
    cmp rbx, r14
    jae .skipline
    inc rbx                         ; space
    ; ---- maxhist ----
    mov rdi, rbx
    mov rsi, r14
    sub rsi, rdi
    call parse_u64
    mov [rsp + 4168], rax           ; keep maxhist
    add rbx, rdx
    cmp rbx, r14
    jae .store0
    inc rbx                         ; space
    ; ---- persona = rest of line ----
    mov r13, rbx
.pl:
    cmp rbx, r14
    jae .pend
    cmp byte [rbx], 10
    je .pend
    inc rbx
    jmp .pl
.pend:
    mov [rsp + 4160], rbx           ; end of persona == end of line
    mov rdx, rbx
    sub rdx, r13                    ; persona length
    mov r15, rdx
    lea rdi, [rsp + 4128]
    mov esi, 1
    call guild_find
    test rax, rax
    jz .nextline
    mov rbx, rax
    mov [rbx + G_MODEL], r12
    mov rax, [rsp + 4168]
    mov [rbx + G_HIST], rax
    test r15, r15
    jz .nextline
    lea rdi, [r15 + 1]
    CALLC malloc
    test rax, rax
    jz .nextline
    mov [rbx + G_PPTR], rax
    mov [rbx + G_PLEN], r15
    mov rdi, rax
    mov rsi, r13
    mov rdx, r15
    CALLC memcpy
    mov rax, [rbx + G_PPTR]
    mov byte [rax + r15], 0
.nextline:
    mov r13, [rsp + 4160]
    inc r13
    jmp .line
.store0:
    lea rdi, [rsp + 4128]
    mov esi, 1
    call guild_find
    test rax, rax
    jz .free
    mov [rax + G_MODEL], r12
    mov rcx, [rsp + 4168]
    mov [rax + G_HIST], rcx
    jmp .free
.skipline:
    ; advance to just after the next newline
    mov r13, rbx
.sk:
    cmp r13, r14
    jae .free
    cmp byte [r13], 10
    je .skn
    inc r13
    jmp .sk
.skn:
    inc r13
    jmp .line
.free:
    lea rdi, [rsp]
    call sb_free
.ret:
    LEAVE_RET

; =====================================================================
; Chat history (in memory)
; =====================================================================

; hist_find(key cstr, create) -> entry* (mutex held)
hist_find:
    ENTER 32
    mov r12, rdi
    mov r13d, esi
    mov rdi, r12
    call c_strlen
    mov r14, rax
    cmp r14, 46
    ja .none
    lea r15, [rel hist_tab]
    xor ebx, ebx
    mov qword [rsp], 0              ; first empty
    mov qword [rsp + 8], 0          ; oldest used
.scan:
    cmp ebx, HKEYS
    jae .miss
    imul rax, rbx, HK_SIZE
    lea rax, [r15 + rax]
    cmp byte [rax], 0
    je .empty
    cmp byte [rax + r14], 0
    jne .used
    mov [rsp + 16], rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r14
    CALLC memcmp
    test eax, eax
    mov rax, [rsp + 16]
    jnz .used
    LEAVE_RET
.used:
    mov rcx, [rsp + 8]
    test rcx, rcx
    jz .seto
    mov rdx, [rax + HK_LAST]
    cmp rdx, [rcx + HK_LAST]
    jae .adv
.seto:
    mov [rsp + 8], rax
    jmp .adv
.empty:
    cmp qword [rsp], 0
    jne .adv
    mov [rsp], rax
.adv:
    inc ebx
    jmp .scan
.miss:
    test r13d, r13d
    jz .none
    mov rbx, [rsp]
    test rbx, rbx
    jnz .init
    mov rbx, [rsp + 8]              ; evict the least recently used key
    mov rdi, rbx
    call hist_wipe
.init:
    mov rdi, rbx
    xor esi, esi
    mov edx, HK_SIZE
    CALLC memset
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    CALLC memcpy
    mov rax, rbx
    LEAVE_RET
.none:
    xor eax, eax
    LEAVE_RET

; hist_wipe(entry*) - free all stored messages (mutex held)
hist_wipe:
    ENTER 0
    mov rbx, rdi
    mov r12, [rbx + HK_ENTS]
    test r12, r12
    jz .done
    xor r13d, r13d
.l:
    cmp r13, [rbx + HK_COUNT]
    jae .fr
    mov rax, [rbx + HK_HEAD]
    add rax, r13
    xor edx, edx
    mov ecx, HCAP
    div rcx
    imul rdx, rdx, HE_SIZE
    mov rdi, [r12 + rdx + 8]
    CALLC free
    inc r13
    jmp .l
.fr:
    mov rdi, r12
    CALLC free
    mov qword [rbx + HK_ENTS], 0
.done:
    mov qword [rbx + HK_COUNT], 0
    mov qword [rbx + HK_HEAD], 0
    LEAVE_RET

; void hist_clear(const char *key)
global hist_clear
hist_clear:
    ENTER 0
    mov r12, rdi
    call state_lock
    mov rdi, r12
    xor esi, esi
    call hist_find
    test rax, rax
    jz .u
    mov rdi, rax
    call hist_wipe
.u:
    call state_unlock
    LEAVE_RET

; void hist_snapshot(const char *key, size_t max_entries, sbuf *out)
; appends {"role":..,"content":..}, objects (with trailing comma)
global hist_snapshot
hist_snapshot:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call state_lock
    mov rdi, r12
    xor esi, esi
    call hist_find
    test rax, rax
    jz .u
    mov rbx, rax
    mov rcx, [rbx + HK_COUNT]
    mov r15, rcx
    cmp r15, r13
    jbe .all
    mov r15, r13
.all:
    ; i runs from count-n .. count-1
    mov r12, [rbx + HK_COUNT]
    sub r12, r15
.l:
    cmp r12, [rbx + HK_COUNT]
    jae .u
    mov rax, [rbx + HK_HEAD]
    add rax, r12
    xor edx, edx
    mov ecx, HCAP
    div rcx
    imul rdx, rdx, HE_SIZE
    add rdx, [rbx + HK_ENTS]
    mov r13, rdx                    ; entry
    mov rdi, r14
    cmp qword [r13], 0
    jne .asst
    lea rsi, [rel s_role_user]
    jmp .a1
.asst:
    lea rsi, [rel s_role_asst]
.a1:
    call sb_appends
    mov rdi, r14
    mov rsi, [r13 + 8]
    mov rdx, [r13 + 16]
    call sb_append
    mov rdi, r14
    lea rsi, [rel s_obj_end]
    call sb_appends
    inc r12
    jmp .l
.u:
    call state_unlock
    LEAVE_RET

; void hist_add(const char *key, int role (0 user /1 assistant), const char *p, size_t n, size_t limit)
global hist_add
hist_add:
    ENTER 16
    mov r12, rdi
    mov [rsp], rsi                  ; role
    mov r13, rdx
    mov r14, rcx
    mov r15, r8                     ; limit (entries)
    cmp r15, HCAP
    jbe .limok
    mov r15d, HCAP
.limok:
    ; cap very long entries on a safe boundary
    cmp r14, HIST_ENTRY_MAX
    jbe .lenok
    mov rdi, r13
    mov rsi, r14
    mov edx, HIST_ENTRY_MAX
    call chunk_next
    mov r14, rax
.lenok:
    lea rdi, [r14 + 1]
    CALLC malloc
    mov rbx, rax
    test rbx, rbx
    jz .ret
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    test rdx, rdx
    jz .nc
    CALLC memcpy
.nc:
    mov byte [rbx + r14], 0
    call state_lock
    mov rdi, r12
    mov esi, 1
    call hist_find
    test rax, rax
    jz .fail
    mov r12, rax
    cmp qword [r12 + HK_ENTS], 0
    jne .hasents
    mov edi, HCAP * HE_SIZE
    CALLC malloc
    test rax, rax
    jz .fail
    mov [r12 + HK_ENTS], rax
.hasents:
    ; drop oldest entries until there is room
.drop:
    mov rcx, [r12 + HK_COUNT]
    test rcx, rcx
    jz .push
    cmp rcx, r15
    jb .push
    mov rdx, [r12 + HK_HEAD]
    imul rax, rdx, HE_SIZE
    add rax, [r12 + HK_ENTS]
    mov rdi, [rax + 8]
    CALLC free
    mov rdx, [r12 + HK_HEAD]
    inc rdx
    cmp rdx, HCAP
    jb .hok
    xor edx, edx
.hok:
    mov [r12 + HK_HEAD], rdx
    dec qword [r12 + HK_COUNT]
    jmp .drop
.push:
    mov rax, [r12 + HK_HEAD]
    add rax, [r12 + HK_COUNT]
    xor edx, edx
    mov ecx, HCAP
    div rcx
    imul rdx, rdx, HE_SIZE
    add rdx, [r12 + HK_ENTS]
    mov rax, [rsp]
    mov [rdx], rax
    mov [rdx + 8], rbx
    mov [rdx + 16], r14
    inc qword [r12 + HK_COUNT]
    call now_ms
    mov [r12 + HK_LAST], rax
    call state_unlock
    jmp .ret
.fail:
    call state_unlock
    mov rdi, rbx
    CALLC free
.ret:
    LEAVE_RET
