/* Steam's web helper GPU switch. Original project contributions: Apache-2.0.
 *
 * Steam draws its whole interface with Chromium (steamwebhelper.exe). Chromium composites
 * in a separate GPU process that draws into windows owned by the browser process. Wine on
 * macOS shows nothing drawn into another process's window: DXMT refuses a swap chain for
 * one ("cross-process swapchain not supported yet"), and with GPU acceleration off the GDI
 * copies never reach the Mac window. Steam's windows open black. Recall avoids the same
 * problem for Battle.net by starting it with --in-process-gpu; Steam has no option that
 * passes it.
 *
 * Steam's web helper loads version.dll from its own folder before Chromium reads its
 * command line (libcef.dll imports it). This is that DLL: in the browser process, the one
 * without --type=, it appends --in-process-gpu to the process's command line. Wine's
 * kernelbase keeps its own pointer to the command line it started with, so the modules
 * already loaded (the helper and libcef.dll among them: Windows binds every import before
 * any DLL initializes) also get a GetCommandLineW that returns the new one. Every version
 * function goes to Wine's kernelbase, as Wine's own version.dll does (version.def). No Steam
 * file is changed; the worker copies this DLL beside steamwebhelper.exe before each launch
 * (Steam updates leave it in place).
 */
#include <windows.h>
#include <winternl.h>

static const WCHAR helper[] = L"\\steamwebhelper.exe";
static const WCHAR child[] = L" --type=";
static const WCHAR added[] = L" --in-process-gpu";
#define COUNT(a) (sizeof(a) / sizeof((a)[0]) - 1)

static BOOL ends_with(const UNICODE_STRING *s, const WCHAR *suffix, size_t n)
{
    size_t length = s->Length / sizeof(WCHAR);
    if (length < n) return FALSE;
    for (size_t i = 0; i < n; i++)
    {
        WCHAR c = s->Buffer[length - n + i];
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (c != suffix[i]) return FALSE;
    }
    return TRUE;
}

static BOOL contains(const UNICODE_STRING *s, const WCHAR *part, size_t n)
{
    size_t length = s->Length / sizeof(WCHAR);
    for (size_t i = 0; i + n <= length; i++)
    {
        size_t j = 0;
        while (j < n && s->Buffer[i + j] == part[j]) j++;
        if (j == n) return TRUE;
    }
    return FALSE;
}

static WCHAR *command_line;
static LPWSTR WINAPI get_command_line(void) { return command_line; }

/* Points every bound import of GetCommandLineW in MODULE at get_command_line. */
static void redirect_imports(BYTE *module, void *const *originals, size_t count)
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)module;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(module + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return;
    IMAGE_DATA_DIRECTORY *directory = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!directory->VirtualAddress || !directory->Size) return;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(module + directory->VirtualAddress); d->Name; d++)
    {
        for (IMAGE_THUNK_DATA64 *thunk = (IMAGE_THUNK_DATA64 *)(module + d->FirstThunk); thunk->u1.Function; thunk++)
        {
            for (size_t i = 0; i < count; i++)
            {
                if ((void *)(ULONG_PTR)thunk->u1.Function != originals[i]) continue;
                DWORD old;
                if (VirtualProtect(&thunk->u1.Function, sizeof(thunk->u1.Function), PAGE_READWRITE, &old))
                {
                    thunk->u1.Function = (ULONGLONG)(ULONG_PTR)get_command_line;
                    VirtualProtect(&thunk->u1.Function, sizeof(thunk->u1.Function), old, &old);
                }
            }
        }
    }
}

static void redirect_loaded_modules(void)
{
    void *originals[2];
    size_t count = 0;
    HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll"), kernelbase = GetModuleHandleW(L"kernelbase.dll");
    if (kernel32 && (originals[count] = (void *)GetProcAddress(kernel32, "GetCommandLineW"))) count++;
    if (kernelbase && (originals[count] = (void *)GetProcAddress(kernelbase, "GetCommandLineW"))) count++;
    if (count == 2 && originals[0] == originals[1]) count = 1;
    PEB_LDR_DATA *loader = NtCurrentTeb()->ProcessEnvironmentBlock->Ldr;
    LIST_ENTRY *head = &loader->InMemoryOrderModuleList;
    for (LIST_ENTRY *entry = head->Flink; entry != head; entry = entry->Flink)
    {
        LDR_DATA_TABLE_ENTRY *module = CONTAINING_RECORD(entry, LDR_DATA_TABLE_ENTRY, InMemoryOrderLinks);
        if (module->DllBase) redirect_imports(module->DllBase, originals, count);
    }
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(instance);
    RTL_USER_PROCESS_PARAMETERS *params = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters;
    UNICODE_STRING *line = &params->CommandLine;
    if (!line->Buffer || !ends_with(&params->ImagePathName, helper, COUNT(helper))) return TRUE;
    if (contains(line, child, COUNT(child)) || contains(line, added + 1, COUNT(added) - 1)) return TRUE;

    size_t bytes = line->Length + sizeof(added);
    if (bytes > 0xfffe) return TRUE;
    WCHAR *buffer = HeapAlloc(GetProcessHeap(), 0, bytes);
    if (!buffer) return TRUE;
    CopyMemory(buffer, line->Buffer, line->Length);
    CopyMemory((BYTE *)buffer + line->Length, added, sizeof(added));
    /* The process keeps this buffer for its lifetime, as it does the original. */
    line->Buffer = buffer;
    line->Length = (USHORT)(bytes - sizeof(WCHAR));
    line->MaximumLength = (USHORT)bytes;
    command_line = buffer;
    redirect_loaded_modules();
    return TRUE;
}

/* The two functions kernelbase doesn't have. Nothing in Steam's web helper calls them;
 * they report that the source file couldn't be read, as an installer would see it. */
DWORD WINAPI VerInstallFileA(DWORD flags, LPSTR source, LPSTR destination, LPSTR source_dir,
                             LPSTR dest_dir, LPSTR current_dir, LPSTR temp, PUINT temp_len)
{
    (void)flags; (void)source; (void)destination; (void)source_dir; (void)dest_dir; (void)current_dir;
    if (temp && temp_len && *temp_len) *temp = 0;
    return VIF_CANNOTREADSRC;
}

DWORD WINAPI VerInstallFileW(DWORD flags, LPWSTR source, LPWSTR destination, LPWSTR source_dir,
                             LPWSTR dest_dir, LPWSTR current_dir, LPWSTR temp, PUINT temp_len)
{
    (void)flags; (void)source; (void)destination; (void)source_dir; (void)dest_dir; (void)current_dir;
    if (temp && temp_len && *temp_len) *temp = 0;
    return VIF_CANNOTREADSRC;
}
