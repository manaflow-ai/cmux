#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::fs::{self, File, OpenOptions};
    use std::io::{BufRead, BufReader, Write};
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{FromRawHandle, RawHandle};
    use std::path::Path;
    use std::ptr::{null, null_mut};
    use std::sync::atomic::{AtomicU64, Ordering};

    use anyhow::{Context, Result, bail};
    use cmux_startup_bootstrap::{
        BootstrapChildStage, BootstrapCommand, BootstrapConfig, BootstrapMessage,
        MAX_BOOTSTRAP_MESSAGE_BYTES,
    };
    use memmap2::{MmapMut, MmapOptions};
    use sha2::{Digest, Sha256};
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{FILE_TYPE_UNKNOWN, GetFileType};
    use windows_sys::Win32::System::JobObjects::IsProcessInJob;
    use windows_sys::Win32::System::Performance::{
        QueryPerformanceCounter, QueryPerformanceFrequency,
    };
    use windows_sys::Win32::System::Threading::{
        CreateProcessW, DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT,
        GetCurrentProcess, GetExitCodeProcess, INFINITE, InitializeProcThreadAttributeList,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROCESS_INFORMATION, ResumeThread, STARTF_USESTDHANDLES,
        STARTUPINFOEXW, UpdateProcThreadAttribute, WaitForSingleObject,
    };

    const PAGE_BYTES: u64 = 4096;
    const MAGIC: &[u8; 8] = b"CMUXT001";
    const MAGIC_OFFSET: usize = 0;
    const NONCE_OFFSET: usize = 8;
    const NONCE_BYTES: usize = 32;
    const T0_OFFSET: usize = 40;
    const GENERATION_OFFSET: usize = 48;

    pub fn run() -> Result<()> {
        let config_path = std::env::args_os()
            .nth(1)
            .map(std::path::PathBuf::from)
            .context("minimal Windows bootstrap requires one config path")?;
        if std::env::args_os().nth(2).is_some() {
            bail!("minimal Windows bootstrap accepts one config path");
        }
        let bytes = fs::read(&config_path)
            .with_context(|| format!("read bootstrap config {}", config_path.display()))?;
        if bytes.len() > MAX_BOOTSTRAP_MESSAGE_BYTES {
            bail!("Windows bootstrap config exceeded its bound");
        }
        let config: BootstrapConfig =
            serde_json::from_slice(&bytes).context("parse strict Windows bootstrap config")?;
        config.validate_identity(&config_path)?;
        validate_launch_paths(&config)?;
        fs::remove_file(&config_path).context("consume Windows bootstrap config")?;

        let nonce = config.nonce.clone();
        let mut input_handle = OwnedHandle::from_transferred(config.control_read, "command pipe")?;
        let mut output_handle = OwnedHandle::from_transferred(config.control_write, "event pipe")?;
        // SAFETY: the trusted outer supervisor transferred sole ownership of these handles.
        let input = unsafe { File::from_raw_handle(input_handle.take() as RawHandle) };
        // SAFETY: this is the paired one-owner transfer for the event pipe.
        let mut output = unsafe { File::from_raw_handle(output_handle.take() as RawHandle) };
        let result = run_inner(config, input, &mut output);
        if let Err(error) = &result {
            let _ = write_message(
                &mut output,
                &BootstrapMessage::Error { nonce, error: format!("{error:#}") },
            );
        }
        result
    }

    fn run_inner(config: BootstrapConfig, input: File, output: &mut File) -> Result<()> {
        write_stage(output, &config.nonce, BootstrapChildStage::ConfigConsumed)?;
        let observed_bootstrap_sha256 = sha256_file(&std::env::current_exe()?)?;
        if observed_bootstrap_sha256 != config.launch.expected_bootstrap_sha256 {
            bail!("minimal Windows bootstrap SHA-256 changed");
        }
        if sha256_file(&config.launch.target)? != config.launch.target_sha256 {
            bail!("Windows bootstrap target SHA-256 changed");
        }
        let trusted_path_write_denied =
            trusted_path_write_denied(&config.launch.trusted_path_probe)?;
        if !trusted_path_write_denied {
            bail!("restricted bootstrap could write its trusted path");
        }
        write_stage(output, &config.nonce, BootstrapChildStage::LaunchValidated)?;

        let standard_handles: [OwnedHandle; 3] = config
            .standard_handles
            .map(|value| OwnedHandle::from_transferred(value, "standard handle"))
            .into_iter()
            .collect::<Result<Vec<_>>>()?
            .try_into()
            .map_err(|_| anyhow::anyhow!("Windows bootstrap requires three standard handles"))?;
        let (standard_handles_valid, standard_handles_inheritable) =
            validate_standard_handles(&standard_handles)?;
        write_stage(output, &config.nonce, BootstrapChildStage::StandardHandlesValidated)?;
        let query_job = OwnedHandle::from_transferred(
            config.query_job.context("private Job query handle is required")?,
            "private Job query handle",
        )?;
        // SAFETY: GetCurrentProcess returns the stable pseudo-handle for this process.
        let private_job_member = process_in_job(unsafe { GetCurrentProcess() }, query_job.0)?;
        let timing = TimingSink::open(&config.launch.timing, &config.nonce)?;
        fs::remove_file(&config.launch.timing).context("consume bootstrap timing page")?;
        write_stage(output, &config.nonce, BootstrapChildStage::TimingConsumed)?;
        write_message(
            output,
            &BootstrapMessage::Ready {
                nonce: config.nonce.clone(),
                bootstrap_sha256: observed_bootstrap_sha256,
                config_consumed: true,
                standard_handles_valid,
                standard_handles_inheritable,
                private_job_member,
                trusted_path_write_denied,
            },
        )?;
        let command: BootstrapCommand = read_message(&mut BufReader::new(input))?;
        match command {
            BootstrapCommand::Arm { nonce } if nonce == config.nonce => {}
            _ => bail!("Windows bootstrap ARM identity mismatch"),
        }
        let (code, private_job_descendant_contained) =
            create_product(&config, standard_handles, &query_job, timing)?;
        write_message(
            output,
            &BootstrapMessage::Exit { nonce: config.nonce, code, private_job_descendant_contained },
        )
    }

    fn validate_launch_paths(config: &BootstrapConfig) -> Result<()> {
        let fixture =
            config.launch.fixture_root.canonicalize().context("resolve bootstrap fixture root")?;
        let target = config.launch.target.canonicalize().context("resolve product binary")?;
        let timing = config.launch.timing.canonicalize().context("resolve timing page")?;
        let probe = config
            .launch
            .trusted_path_probe
            .canonicalize()
            .context("resolve trusted-path write probe")?;
        if !fixture.is_dir()
            || !target.is_file()
            || !timing.is_file()
            || !probe.is_file()
            || target.starts_with(&fixture)
            || probe.starts_with(&fixture)
            || timing.parent() != Some(fixture.as_path())
        {
            bail!("Windows bootstrap launch paths violated their filesystem boundary");
        }
        Ok(())
    }

    fn create_product(
        config: &BootstrapConfig,
        standard_handles: [OwnedHandle; 3],
        query_job: &OwnedHandle,
        timing: TimingSink,
    ) -> Result<(u32, bool)> {
        let handles = standard_handles.each_ref().map(|handle| handle.0);
        let attributes = ProcessAttributeList::for_handles(&handles)?;
        let application = wide(config.launch.target.as_os_str());
        let current_directory = wide(config.launch.fixture_root.as_os_str());
        let mut command_line = wide(std::ffi::OsStr::new(&windows_command_line(
            &config.launch.target,
            &config.launch.product_args,
        )));
        // SAFETY: zero is a valid initial state for these Win32 structures.
        let mut startup: STARTUPINFOEXW = unsafe { zeroed() };
        startup.StartupInfo.cb = u32::try_from(size_of::<STARTUPINFOEXW>())?;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = handles[0];
        startup.StartupInfo.hStdOutput = handles[1];
        startup.StartupInfo.hStdError = handles[2];
        startup.lpAttributeList = attributes.pointer;
        // SAFETY: zero is a valid initial PROCESS_INFORMATION state.
        let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
        timing.record_pre_exec()?;
        let created = unsafe {
            CreateProcessW(
                application.as_ptr(),
                command_line.as_mut_ptr(),
                null(),
                null(),
                1,
                windows_sys::Win32::System::Threading::CREATE_SUSPENDED
                    | EXTENDED_STARTUPINFO_PRESENT,
                null(),
                current_directory.as_ptr(),
                &startup.StartupInfo,
                &mut process,
            )
        };
        if created == 0 {
            return Err(std::io::Error::last_os_error()).context("create restricted product");
        }
        let process_handle = OwnedHandle(process.hProcess);
        let thread_handle = OwnedHandle(process.hThread);
        let contained = process_in_job(process_handle.0, query_job.0)?;
        if unsafe { ResumeThread(thread_handle.0) } == u32::MAX {
            return Err(std::io::Error::last_os_error()).context("resume restricted product");
        }
        if unsafe { WaitForSingleObject(process_handle.0, INFINITE) }
            != windows_sys::Win32::Foundation::WAIT_OBJECT_0
        {
            return Err(std::io::Error::last_os_error()).context("wait for restricted product");
        }
        let mut code = 0;
        if unsafe { GetExitCodeProcess(process_handle.0, &mut code) } == 0 {
            return Err(std::io::Error::last_os_error()).context("read restricted product status");
        }
        Ok((code, contained))
    }

    fn write_stage(output: &mut File, nonce: &str, stage: BootstrapChildStage) -> Result<()> {
        write_message(output, &BootstrapMessage::Stage { nonce: nonce.into(), stage })
    }

    fn write_message(output: &mut File, message: &BootstrapMessage) -> Result<()> {
        let bytes = serde_json::to_vec(message)?;
        if bytes.len() > MAX_BOOTSTRAP_MESSAGE_BYTES {
            bail!("Windows bootstrap message exceeded its bound");
        }
        output.write_all(&bytes)?;
        output.write_all(b"\n")?;
        output.flush()?;
        Ok(())
    }

    fn read_message<T: serde::de::DeserializeOwned>(reader: &mut impl BufRead) -> Result<T> {
        let mut line = Vec::new();
        reader.read_until(b'\n', &mut line)?;
        if line.is_empty() || line.len() > MAX_BOOTSTRAP_MESSAGE_BYTES {
            bail!("Windows bootstrap command was empty or exceeded its bound");
        }
        Ok(serde_json::from_slice(&line)?)
    }

    fn sha256_file(path: &Path) -> Result<String> {
        let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
        Ok(format!("{:x}", Sha256::digest(bytes)))
    }

    fn trusted_path_write_denied(path: &Path) -> Result<bool> {
        match OpenOptions::new().write(true).open(path) {
            Ok(_) => Ok(false),
            Err(error) if error.raw_os_error() == Some(5) => Ok(true),
            Err(error) => {
                Err(error).with_context(|| format!("probe trusted path {}", path.display()))
            }
        }
    }

    fn validate_standard_handles(handles: &[OwnedHandle; 3]) -> Result<(bool, bool)> {
        let mut inheritable = true;
        for handle in handles {
            if unsafe { GetFileType(handle.0) } == FILE_TYPE_UNKNOWN
                && std::io::Error::last_os_error().raw_os_error().unwrap_or_default() != 0
            {
                bail!("Windows bootstrap received an invalid standard handle");
            }
            let mut flags = 0;
            if unsafe { GetHandleInformation(handle.0, &mut flags) } == 0 {
                return Err(std::io::Error::last_os_error())
                    .context("inspect bootstrap standard handle");
            }
            inheritable &= flags & HANDLE_FLAG_INHERIT != 0;
        }
        Ok((true, inheritable))
    }

    fn process_in_job(process: HANDLE, job: HANDLE) -> Result<bool> {
        let mut contained = 0;
        if unsafe { IsProcessInJob(process, job, &mut contained) } == 0 {
            return Err(std::io::Error::last_os_error())
                .context("query exact private Job membership");
        }
        Ok(contained != 0)
    }

    struct ProcessAttributeList {
        storage: Vec<usize>,
        pointer: windows_sys::Win32::System::Threading::LPPROC_THREAD_ATTRIBUTE_LIST,
    }

    impl ProcessAttributeList {
        fn for_handles(handles: &[HANDLE; 3]) -> Result<Self> {
            let mut bytes = 0;
            unsafe { InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut bytes) };
            let words = bytes.div_ceil(size_of::<usize>());
            let mut storage = vec![0_usize; words];
            let pointer = storage.as_mut_ptr().cast();
            if unsafe { InitializeProcThreadAttributeList(pointer, 1, 0, &mut bytes) } == 0 {
                return Err(std::io::Error::last_os_error())
                    .context("initialize product handle list");
            }
            if unsafe {
                UpdateProcThreadAttribute(
                    pointer,
                    0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                    handles.as_ptr().cast_mut().cast::<c_void>(),
                    size_of::<[HANDLE; 3]>(),
                    null_mut(),
                    null_mut(),
                )
            } == 0
            {
                unsafe { DeleteProcThreadAttributeList(pointer) };
                return Err(std::io::Error::last_os_error()).context("install product handle list");
            }
            Ok(Self { storage, pointer })
        }
    }

    impl Drop for ProcessAttributeList {
        fn drop(&mut self) {
            unsafe { DeleteProcThreadAttributeList(self.pointer) };
            self.storage.clear();
        }
    }

    struct TimingSink {
        mapping: MmapMut,
        nonce: [u8; NONCE_BYTES],
    }

    impl TimingSink {
        fn open(path: &Path, expected_nonce: &str) -> Result<Self> {
            let nonce = decode_nonce(expected_nonce)?;
            let file = OpenOptions::new().read(true).write(true).open(path)?;
            if file.metadata()?.len() != PAGE_BYTES {
                bail!("launch timing page has the wrong size");
            }
            let mapping = unsafe { MmapOptions::new().map_mut(&file)? };
            if &mapping[MAGIC_OFFSET..MAGIC_OFFSET + MAGIC.len()] != MAGIC
                || mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES] != nonce
            {
                bail!("launch timing page identity mismatch");
            }
            Ok(Self { mapping, nonce })
        }

        fn record_pre_exec(&self) -> std::io::Result<()> {
            if self.mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES] != self.nonce {
                return Err(std::io::Error::other("launch timing nonce changed"));
            }
            let generation = atomic(&self.mapping, GENERATION_OFFSET);
            generation
                .compare_exchange(0, u64::MAX, Ordering::AcqRel, Ordering::Acquire)
                .map_err(|_| std::io::Error::other("launch timing page was already armed"))?;
            atomic(&self.mapping, T0_OFFSET).store(monotonic_ns()?, Ordering::Relaxed);
            generation.store(1, Ordering::Release);
            Ok(())
        }
    }

    fn atomic(mapping: &[u8], offset: usize) -> &AtomicU64 {
        unsafe { &*mapping.as_ptr().add(offset).cast::<AtomicU64>() }
    }

    fn monotonic_ns() -> std::io::Result<u64> {
        let mut counter = 0_i64;
        let mut frequency = 0_i64;
        if unsafe { QueryPerformanceCounter(&mut counter) } == 0
            || unsafe { QueryPerformanceFrequency(&mut frequency) } == 0
            || counter < 0
            || frequency <= 0
        {
            return Err(std::io::Error::last_os_error());
        }
        u64::try_from((counter as u128 * 1_000_000_000_u128) / frequency as u128)
            .map_err(|_| std::io::Error::other("monotonic timestamp overflow"))
    }

    fn decode_nonce(value: &str) -> Result<[u8; NONCE_BYTES]> {
        if value.len() != NONCE_BYTES * 2 {
            bail!("nonce has the wrong length");
        }
        let mut nonce = [0_u8; NONCE_BYTES];
        for (index, byte) in nonce.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)?;
        }
        Ok(nonce)
    }

    fn windows_command_line(program: &Path, arguments: &[String]) -> String {
        std::iter::once(program.to_string_lossy().into_owned())
            .chain(arguments.iter().cloned())
            .map(|argument| quote_windows_argument(&argument))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn quote_windows_argument(argument: &str) -> String {
        let mut quoted = String::from("\"");
        let mut backslashes = 0;
        for character in argument.chars() {
            match character {
                '\\' => backslashes += 1,
                '"' => {
                    quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                    quoted.push('"');
                    backslashes = 0;
                }
                _ => {
                    quoted.push_str(&"\\".repeat(backslashes));
                    quoted.push(character);
                    backslashes = 0;
                }
            }
        }
        quoted.push_str(&"\\".repeat(backslashes * 2));
        quoted.push('"');
        quoted
    }

    fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }

    struct OwnedHandle(HANDLE);

    impl OwnedHandle {
        fn from_transferred(value: usize, name: &str) -> Result<Self> {
            let handle = value as HANDLE;
            if handle.is_null() || handle == INVALID_HANDLE_VALUE {
                bail!("transferred Windows {name} is invalid");
            }
            Ok(Self(handle))
        }

        fn take(&mut self) -> HANDLE {
            std::mem::replace(&mut self.0, null_mut())
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CloseHandle(self.0) };
            }
        }
    }
}

fn main() {
    #[cfg(windows)]
    if let Err(error) = windows::run() {
        eprintln!("cmux startup bootstrap: {error:#}");
        std::process::exit(125);
    }

    #[cfg(not(windows))]
    {
        eprintln!("cmux startup bootstrap is Windows-only");
        std::process::exit(125);
    }
}
