// Minimal CEF helper process for cmux.
//
// CEF uses a multi-process architecture. This executable is launched
// by CEF for renderer, GPU, and other subprocess types. It simply
// calls CefExecuteProcess and exits.

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
    CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInHelper()) {
        return 1;
    }

    CefMainArgs main_args(argc, argv);
    return CefExecuteProcess(main_args, nullptr, nullptr);
}
