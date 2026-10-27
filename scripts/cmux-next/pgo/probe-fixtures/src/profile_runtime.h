// The compiler-rt profile runtime entry points that -profile-generate links in.
int __llvm_profile_write_file(void);
void __llvm_profile_reset_counters(void);
void __llvm_profile_set_filename(const char *name);
