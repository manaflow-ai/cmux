use std::ffi::{OsStr, c_void};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::mem::{size_of, zeroed};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_INSUFFICIENT_BUFFER,
    ERROR_INVALID_DATA, GetLastError, HANDLE, HMODULE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0,
    WAIT_TIMEOUT,
};
use windows_sys::Win32::System::Diagnostics::Debug::{
    CONTEXT, CONTEXT_CONTROL_AMD64, CloseThreadWaitChainSession, GetThreadContext,
    GetThreadWaitChain, MiniDumpWithThreadInfo, MiniDumpWriteDump, OpenThreadWaitChainSession,
    ReadProcessMemory, WAITCHAIN_NODE_INFO, WCT_MAX_NODE_COUNT, WctThreadType,
};
use windows_sys::Win32::System::JobObjects::IsProcessInJob;
use windows_sys::Win32::System::Memory::{MEMORY_BASIC_INFORMATION, VirtualQueryEx};
use windows_sys::Win32::System::ProcessStatus::{
    K32EnumProcessModulesEx, K32GetMappedFileNameW, K32GetModuleFileNameExW,
    K32GetModuleInformation, LIST_MODULES_ALL, MODULEINFO,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
    GetCurrentProcess, GetExitCodeProcess, GetProcessId, GetThreadId, PROCESS_INFORMATION,
    ResumeThread, STARTUPINFOW, SuspendThread, TerminateProcess, WaitForSingleObject,
};

use crate::startup_benchmark_protocol::{
    BOOTSTRAP_HANG_CAPTURE_TIMEOUT, BootstrapHangArtifactReference, BootstrapHangDiagnosticReport,
    BootstrapHangInstructionWindow, BootstrapHangModule, BootstrapHangThreadContext,
    BootstrapHangWaitChain, BootstrapHangWaitChainNode, MAX_BOOTSTRAP_HANG_DUMP_BYTES,
    MAX_BOOTSTRAP_HANG_REPORT_BYTES,
};

const CONFIG_SCHEMA_VERSION: u32 = 1;
const MAX_CONFIG_BYTES: u64 = 32 * 1024;
const MAX_MODULES: usize = 256;

pub struct CaptureRequest<'a> {
    pub process: HANDLE,
    pub primary_thread: HANDLE,
    pub process_id: u32,
    pub primary_thread_id: u32,
    pub private_job: HANDLE,
    pub fixture_root: &'a Path,
    pub nonce: &'a str,
    pub supervisor_sha256: &'a str,
    pub target_cmux_bench_environment_filtered: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HelperConfig {
    schema_version: u32,
    launch_nonce: String,
    helper_nonce: String,
    process_handle: u64,
    primary_thread_handle: u64,
    process_id: u32,
    primary_thread_id: u32,
    fixture_root: PathBuf,
    report_path: PathBuf,
    dump_path: PathBuf,
    supervisor_sha256: String,
    target_cmux_bench_environment_filtered: bool,
}

#[derive(Debug, Serialize)]
struct HelperFailure<'a> {
    schema_version: u32,
    nonce: &'a str,
    captured: bool,
    error: &'a str,
}

struct HelperInvocation {
    config_path: PathBuf,
    launch_nonce: String,
    helper_nonce: String,
    report_path: PathBuf,
}

struct ModuleMapCapture {
    modules: Vec<BootstrapHangModule>,
    windows_error: Option<u32>,
}

struct InstructionOwnerCapture {
    path: Option<String>,
    base_address: Option<u64>,
    offset: Option<u64>,
    source: Option<String>,
    windows_error: Option<u32>,
}

pub fn capture(request: CaptureRequest<'_>) -> Result<BootstrapHangArtifactReference> {
    validate_nonce(request.nonce)?;
    let fixture_root = request.fixture_root.canonicalize()?;
    let current_exe = std::env::current_exe()?.canonicalize()?;
    verify_sha256(&current_exe, request.supervisor_sha256, "trusted diagnostic helper")?;

    let suffix = &request.nonce[..16];
    let mut helper_nonce_bytes = [0_u8; 32];
    getrandom::fill(&mut helper_nonce_bytes).map_err(|error| anyhow::anyhow!(error.to_string()))?;
    let helper_nonce =
        helper_nonce_bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let config_path =
        fixture_root.join(format!("bootstrap-hang-config-{}.json", &helper_nonce[..16]));
    let report_path = fixture_root.join(format!("bootstrap-hang-{suffix}.json"));
    let dump_path = fixture_root.join(format!("bootstrap-hang-{suffix}.dmp"));
    for path in [&config_path, &report_path, &dump_path] {
        validate_new_artifact_path(path, &fixture_root)?;
    }

    let application = wide(current_exe.as_os_str());
    let mut command_line = wide(OsStr::new(&windows_command_line(
        &current_exe,
        &[
            "--windows-hang-diagnostic".into(),
            "--config".into(),
            config_path.to_string_lossy().into_owned(),
            "--nonce".into(),
            request.nonce.into(),
            "--helper-nonce".into(),
            helper_nonce.clone(),
            "--output".into(),
            report_path.to_string_lossy().into_owned(),
        ],
    )));
    let current_directory = wide(fixture_root.as_os_str());
    let mut helper_environment = filtered_helper_environment_block();
    if !cmux_bench_environment_is_filtered(&helper_environment, &[]) {
        bail!("trusted diagnostic helper environment retained a CMUX_BENCH value");
    }
    let mut startup: STARTUPINFOW = unsafe { zeroed() };
    startup.cb = u32::try_from(size_of::<STARTUPINFOW>())?;
    let mut process: PROCESS_INFORMATION = unsafe { zeroed() };

    // The helper starts suspended. The outer supervisor can now duplicate the two existing target
    // handles and publish their helper-local values before any diagnostic code runs.
    check(
        unsafe {
            CreateProcessW(
                application.as_ptr(),
                command_line.as_mut_ptr(),
                null(),
                null(),
                0,
                CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                helper_environment.as_mut_ptr().cast::<c_void>(),
                current_directory.as_ptr(),
                &startup,
                &mut process,
            )
        },
        "create suspended trusted hang diagnostic helper",
    )?;
    let helper_process = OwnedHandle(process.hProcess);
    let helper_thread = OwnedHandle(process.hThread);
    let result = (|| {
        let mut in_private_job = 0;
        check(
            unsafe { IsProcessInJob(helper_process.0, request.private_job, &mut in_private_job) },
            "query diagnostic helper private Job membership",
        )?;
        if in_private_job != 0 {
            bail!("trusted hang diagnostic helper entered the measured private Job");
        }
        let process_handle = duplicate_into_process(
            request.process,
            helper_process.0,
            "restricted bootstrap process",
        )?;
        let primary_thread_handle = duplicate_into_process(
            request.primary_thread,
            helper_process.0,
            "restricted bootstrap primary thread",
        )?;
        let config = HelperConfig {
            schema_version: CONFIG_SCHEMA_VERSION,
            launch_nonce: request.nonce.into(),
            helper_nonce,
            process_handle: process_handle as usize as u64,
            primary_thread_handle: primary_thread_handle as usize as u64,
            process_id: request.process_id,
            primary_thread_id: request.primary_thread_id,
            fixture_root: fixture_root.clone(),
            report_path: report_path.clone(),
            dump_path: dump_path.clone(),
            supervisor_sha256: request.supervisor_sha256.into(),
            target_cmux_bench_environment_filtered: request.target_cmux_bench_environment_filtered,
        };
        let config_bytes = serde_json::to_vec(&config)?;
        if u64::try_from(config_bytes.len())? > MAX_CONFIG_BYTES {
            bail!("bootstrap hang helper config exceeded its bound");
        }
        write_create_new(&config_path, &config_bytes, MAX_CONFIG_BYTES)?;

        let previous = unsafe { ResumeThread(helper_thread.0) };
        if previous != 1 {
            if previous == u32::MAX {
                return Err(std::io::Error::last_os_error())
                    .context("resume trusted hang diagnostic helper");
            }
            bail!("diagnostic helper primary thread had suspend count {previous}, expected 1");
        }
        wait_for_helper(&helper_process, BOOTSTRAP_HANG_CAPTURE_TIMEOUT)?;
        let mut exit_code = 0;
        check(
            unsafe { GetExitCodeProcess(helper_process.0, &mut exit_code) },
            "read trusted hang diagnostic helper exit code",
        )?;
        verify_sha256(
            &current_exe,
            request.supervisor_sha256,
            "trusted diagnostic helper after capture",
        )?;
        if exit_code != 0 {
            let detail = read_helper_failure(&report_path, request.nonce)
                .unwrap_or_else(|error| format!("unavailable failure record: {error:#}"));
            bail!("trusted hang diagnostic helper exited {exit_code}: {detail}");
        }
        validate_completed_artifacts(&report_path, &dump_path, request.nonce)
    })();

    if result.is_err() {
        let _ = unsafe { TerminateProcess(helper_process.0, 125) };
        let _ = unsafe { WaitForSingleObject(helper_process.0, u32::MAX) };
    }
    match fs::remove_file(&config_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) if result.is_err() => {
            return result.context(format!(
                "remove failed diagnostic helper config {}: {error}",
                config_path.display()
            ));
        }
        Err(error) => return Err(error).context("remove diagnostic helper config"),
    }
    result
}

pub fn run_helper(values: &[String]) -> Result<()> {
    let invocation = parse_helper_invocation(values)?;
    let result = run_helper_inner(&invocation);
    if let Err(error) = &result {
        let bounded = bounded_text(&format!("{error:#}"), 2_048);
        let failure = HelperFailure {
            schema_version: 1,
            nonce: &invocation.launch_nonce,
            captured: false,
            error: &bounded,
        };
        if let Ok(bytes) = serde_json::to_vec(&failure) {
            let _ =
                write_create_new(&invocation.report_path, &bytes, MAX_BOOTSTRAP_HANG_REPORT_BYTES);
        }
    }
    result
}

fn run_helper_inner(invocation: &HelperInvocation) -> Result<()> {
    validate_nonce(&invocation.launch_nonce)?;
    validate_nonce(&invocation.helper_nonce)?;
    let config_bytes = read_bounded_regular_file(&invocation.config_path, MAX_CONFIG_BYTES)?;
    let config: HelperConfig = serde_json::from_slice(&config_bytes)?;
    if config.schema_version != CONFIG_SCHEMA_VERSION
        || config.launch_nonce != invocation.launch_nonce
        || config.helper_nonce != invocation.helper_nonce
    {
        bail!("bootstrap hang helper config identity or schema mismatch");
    }
    if config.report_path != invocation.report_path {
        bail!("bootstrap hang helper report path mismatch");
    }
    let fixture_root = config.fixture_root.canonicalize()?;
    validate_new_artifact_path(&config.report_path, &fixture_root)?;
    validate_new_artifact_path(&config.dump_path, &fixture_root)?;
    if invocation.config_path.parent() != Some(fixture_root.as_path()) {
        bail!("bootstrap hang helper config escaped the fixture root");
    }
    verify_sha256(
        &std::env::current_exe()?.canonicalize()?,
        &config.supervisor_sha256,
        "running trusted diagnostic helper",
    )?;
    let helper_cmux_bench_environment_filtered =
        std::env::vars_os().all(|(key, _)| !key.to_string_lossy().starts_with("CMUX_BENCH_"));
    if !helper_cmux_bench_environment_filtered {
        bail!("trusted diagnostic helper inherited a CMUX_BENCH value");
    }
    fs::remove_file(&invocation.config_path).context("consume bootstrap hang helper config")?;

    let process = owned_remote_handle(config.process_handle, "restricted bootstrap process")?;
    let primary_thread =
        owned_remote_handle(config.primary_thread_handle, "restricted bootstrap primary thread")?;
    if unsafe { GetProcessId(process.0) } != config.process_id
        || unsafe { GetThreadId(primary_thread.0) } != config.primary_thread_id
    {
        bail!("bootstrap hang helper handle identity mismatch");
    }

    let wait_chain = capture_wait_chain(config.primary_thread_id);
    let suspended_previous_count = unsafe { SuspendThread(primary_thread.0) };
    if suspended_previous_count == u32::MAX {
        return Err(std::io::Error::last_os_error())
            .context("suspend restricted bootstrap primary thread for capture");
    }
    let context = capture_thread_context(&primary_thread)?;
    let module_map = capture_modules(&process);
    let instruction_owner = capture_instruction_owner(&process, context.0, &module_map.modules);
    let thread_context = BootstrapHangThreadContext {
        instruction_pointer: context.0,
        stack_pointer: context.1,
        module_path: instruction_owner.path,
        module_base_address: instruction_owner.base_address,
        module_offset: instruction_owner.offset,
        owner_source: instruction_owner.source,
        mapping_windows_error: instruction_owner.windows_error,
        instruction_window: capture_instruction_window(&process, context.0),
    };
    let dump = write_minidump(&process, config.process_id, &config.dump_path)?;
    let report = BootstrapHangDiagnosticReport {
        schema_version: 1,
        nonce: config.launch_nonce.clone(),
        process_id: config.process_id,
        primary_thread_id: config.primary_thread_id,
        suspended_previous_count,
        context: thread_context,
        modules: module_map.modules,
        module_map_windows_error: module_map.windows_error,
        wait_chain,
        dump_name: file_name(&config.dump_path)?,
        dump_sha256: dump.0,
        dump_bytes: dump.1,
        cmux_bench_environment_filtered: config.target_cmux_bench_environment_filtered,
        helper_cmux_bench_environment_filtered,
    };
    report.validate(&config.launch_nonce)?;
    let bytes = serde_json::to_vec_pretty(&report)?;
    write_create_new(&config.report_path, &bytes, MAX_BOOTSTRAP_HANG_REPORT_BYTES)
}

fn parse_helper_invocation(values: &[String]) -> Result<HelperInvocation> {
    let mut config_path = None;
    let mut launch_nonce = None;
    let mut helper_nonce = None;
    let mut report_path = None;
    let mut index = 0;
    while index < values.len() {
        let key = &values[index];
        let value = values.get(index + 1).with_context(|| format!("{key} requires a value"))?;
        match key.as_str() {
            "--config" => config_path = Some(PathBuf::from(value)),
            "--nonce" => launch_nonce = Some(value.clone()),
            "--helper-nonce" => helper_nonce = Some(value.clone()),
            "--output" => report_path = Some(PathBuf::from(value)),
            _ => bail!("unknown Windows hang diagnostic argument {key}"),
        }
        index += 2;
    }
    Ok(HelperInvocation {
        config_path: config_path.context("--config is required")?,
        launch_nonce: launch_nonce.context("--nonce is required")?,
        helper_nonce: helper_nonce.context("--helper-nonce is required")?,
        report_path: report_path.context("--output is required")?,
    })
}

fn capture_wait_chain(thread_id: u32) -> BootstrapHangWaitChain {
    let session = unsafe { OpenThreadWaitChainSession(0, None) };
    if session.is_null() {
        return BootstrapHangWaitChain {
            captured: false,
            cycle: false,
            windows_error: Some(unsafe { GetLastError() }),
            nodes: Vec::new(),
        };
    }
    let mut raw_nodes = [WAITCHAIN_NODE_INFO::default(); WCT_MAX_NODE_COUNT as usize];
    let mut node_count = WCT_MAX_NODE_COUNT;
    let mut cycle = 0;
    let captured = unsafe {
        GetThreadWaitChain(
            session,
            0,
            0,
            thread_id,
            &mut node_count,
            raw_nodes.as_mut_ptr(),
            &mut cycle,
        )
    };
    let error = (captured == 0).then(|| unsafe { GetLastError() });
    unsafe { CloseThreadWaitChainSession(session) };
    let nodes = if captured == 0 {
        Vec::new()
    } else {
        raw_nodes[..usize::try_from(node_count).unwrap_or(0).min(raw_nodes.len())]
            .iter()
            .map(|node| {
                if node.ObjectType == WctThreadType {
                    let thread = unsafe { node.Anonymous.ThreadObject };
                    BootstrapHangWaitChainNode {
                        object_type: node.ObjectType,
                        object_status: node.ObjectStatus,
                        process_id: Some(thread.ProcessId),
                        thread_id: Some(thread.ThreadId),
                        object_name: None,
                    }
                } else {
                    let lock = unsafe { node.Anonymous.LockObject };
                    BootstrapHangWaitChainNode {
                        object_type: node.ObjectType,
                        object_status: node.ObjectStatus,
                        process_id: None,
                        thread_id: None,
                        object_name: Some(utf16_z(&lock.ObjectName)),
                    }
                }
            })
            .collect()
    };
    BootstrapHangWaitChain {
        captured: captured != 0,
        cycle: cycle != 0,
        windows_error: error,
        nodes,
    }
}

#[cfg(target_arch = "x86_64")]
fn capture_thread_context(thread: &OwnedHandle) -> Result<(u64, u64)> {
    let mut context: CONTEXT = unsafe { zeroed() };
    context.ContextFlags = CONTEXT_CONTROL_AMD64;
    check(
        unsafe { GetThreadContext(thread.0, &mut context) },
        "capture restricted bootstrap primary-thread context",
    )?;
    Ok((context.Rip, context.Rsp))
}

#[cfg(not(target_arch = "x86_64"))]
fn capture_thread_context(_thread: &OwnedHandle) -> Result<(u64, u64)> {
    bail!("Windows bootstrap hang diagnostics require an x86-64 runner")
}

fn capture_modules(process: &OwnedHandle) -> ModuleMapCapture {
    let mut modules: [HMODULE; MAX_MODULES] = [null_mut(); MAX_MODULES];
    let mut bytes_needed = 0;
    let buffer_bytes = u32::try_from(size_of::<HANDLE>() * modules.len())
        .expect("bounded module handle array fits in u32");
    if unsafe {
        K32EnumProcessModulesEx(
            process.0,
            modules.as_mut_ptr(),
            buffer_bytes,
            &mut bytes_needed,
            LIST_MODULES_ALL,
        )
    } == 0
    {
        return ModuleMapCapture {
            modules: Vec::new(),
            windows_error: Some(last_windows_error_or(ERROR_INVALID_DATA)),
        };
    }
    let bytes_needed = usize::try_from(bytes_needed).unwrap_or(usize::MAX);
    if bytes_needed == 0 || !bytes_needed.is_multiple_of(size_of::<HANDLE>()) {
        return ModuleMapCapture { modules: Vec::new(), windows_error: Some(ERROR_INVALID_DATA) };
    }
    let count = bytes_needed / size_of::<HANDLE>();
    if count > modules.len() {
        return ModuleMapCapture {
            modules: Vec::new(),
            windows_error: Some(ERROR_INSUFFICIENT_BUFFER),
        };
    }

    let mut captured = Vec::with_capacity(count);
    let mut first_error = None;
    for module in &modules[..count] {
        let mut information: MODULEINFO = unsafe { zeroed() };
        if unsafe {
            K32GetModuleInformation(
                process.0,
                *module,
                &mut information,
                u32::try_from(size_of::<MODULEINFO>()).expect("MODULEINFO size fits in u32"),
            )
        } == 0
        {
            first_error.get_or_insert_with(|| last_windows_error_or(ERROR_INVALID_DATA));
            continue;
        }
        if information.SizeOfImage == 0 {
            first_error.get_or_insert(ERROR_INVALID_DATA);
            continue;
        }
        let mut path = vec![0_u16; 32 * 1024];
        let length = unsafe {
            K32GetModuleFileNameExW(
                process.0,
                *module,
                path.as_mut_ptr(),
                u32::try_from(path.len()).expect("bounded module path length fits in u32"),
            )
        };
        let length = usize::try_from(length).unwrap_or(usize::MAX);
        if length == 0 || length >= path.len() {
            first_error.get_or_insert_with(|| {
                if length >= path.len() {
                    ERROR_INSUFFICIENT_BUFFER
                } else {
                    last_windows_error_or(ERROR_INVALID_DATA)
                }
            });
            continue;
        }
        path.truncate(length);
        captured.push(BootstrapHangModule {
            base_address: information.lpBaseOfDll as usize as u64,
            size: information.SizeOfImage,
            path: String::from_utf16_lossy(&path),
        });
    }
    if captured.is_empty() && first_error.is_none() {
        first_error = Some(ERROR_INVALID_DATA);
    }
    ModuleMapCapture { modules: captured, windows_error: first_error }
}

fn capture_instruction_owner(
    process: &OwnedHandle,
    instruction_pointer: u64,
    modules: &[BootstrapHangModule],
) -> InstructionOwnerCapture {
    if let Some(module) = modules.iter().find(|module| {
        let end = module.base_address.saturating_add(u64::from(module.size));
        (module.base_address..end).contains(&instruction_pointer)
    }) {
        return InstructionOwnerCapture {
            path: Some(module.path.clone()),
            base_address: Some(module.base_address),
            offset: Some(instruction_pointer.saturating_sub(module.base_address)),
            source: Some("module-map".into()),
            windows_error: None,
        };
    }

    let address = instruction_pointer as usize as *const c_void;
    let mut information: MEMORY_BASIC_INFORMATION = unsafe { zeroed() };
    let queried = unsafe {
        VirtualQueryEx(process.0, address, &mut information, size_of::<MEMORY_BASIC_INFORMATION>())
    };
    if queried == 0 {
        return InstructionOwnerCapture::failed(last_windows_error_or(ERROR_INVALID_DATA));
    }
    if information.AllocationBase.is_null() {
        return InstructionOwnerCapture::failed(ERROR_INVALID_DATA);
    }
    let base_address = information.AllocationBase as usize as u64;
    if instruction_pointer < base_address {
        return InstructionOwnerCapture::failed(ERROR_INVALID_DATA);
    }
    let mut path = vec![0_u16; 32 * 1024];
    let length = unsafe {
        K32GetMappedFileNameW(
            process.0,
            address,
            path.as_mut_ptr(),
            u32::try_from(path.len()).expect("bounded mapped-file path length fits in u32"),
        )
    };
    let length = usize::try_from(length).unwrap_or(usize::MAX);
    if length == 0 || length >= path.len() {
        return InstructionOwnerCapture::failed(if length >= path.len() {
            ERROR_INSUFFICIENT_BUFFER
        } else {
            last_windows_error_or(ERROR_INVALID_DATA)
        });
    }
    path.truncate(length);
    InstructionOwnerCapture {
        path: Some(String::from_utf16_lossy(&path)),
        base_address: Some(base_address),
        offset: Some(instruction_pointer - base_address),
        source: Some("virtual-query".into()),
        windows_error: None,
    }
}

impl InstructionOwnerCapture {
    fn failed(windows_error: u32) -> Self {
        Self {
            path: None,
            base_address: None,
            offset: None,
            source: None,
            windows_error: Some(windows_error),
        }
    }
}

fn last_windows_error_or(fallback: u32) -> u32 {
    let error = unsafe { GetLastError() };
    if error == 0 { fallback } else { error }
}

fn capture_instruction_window(
    process: &OwnedHandle,
    instruction_pointer: u64,
) -> BootstrapHangInstructionWindow {
    const WINDOW_BYTES: usize = 32;
    let start_address = instruction_pointer.saturating_sub((WINDOW_BYTES / 2) as u64);
    let mut bytes = [0_u8; WINDOW_BYTES];
    let mut bytes_read = 0;
    let captured = unsafe {
        ReadProcessMemory(
            process.0,
            start_address as usize as *const c_void,
            bytes.as_mut_ptr().cast::<c_void>(),
            bytes.len(),
            &mut bytes_read,
        )
    };
    if captured == 0 || bytes_read == 0 {
        return BootstrapHangInstructionWindow {
            start_address,
            bytes_hex: None,
            windows_error: Some(last_windows_error_or(ERROR_INVALID_DATA)),
        };
    }
    BootstrapHangInstructionWindow {
        start_address,
        bytes_hex: Some(
            bytes[..bytes_read.min(bytes.len())].iter().map(|byte| format!("{byte:02x}")).collect(),
        ),
        windows_error: None,
    }
}

fn write_minidump(process: &OwnedHandle, process_id: u32, path: &Path) -> Result<(String, u64)> {
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("create bootstrap minidump {}", path.display()))?;
    let file_handle = file.as_raw_handle() as HANDLE;
    check(
        unsafe {
            MiniDumpWriteDump(
                process.0,
                process_id,
                file_handle,
                MiniDumpWithThreadInfo,
                null(),
                null(),
                null(),
            )
        },
        "write minimal restricted bootstrap minidump",
    )?;
    file.sync_data()?;
    let bytes = file.metadata()?.len();
    drop(file);
    if bytes == 0 || bytes > MAX_BOOTSTRAP_HANG_DUMP_BYTES {
        let _ = fs::remove_file(path);
        bail!("bootstrap minidump size {bytes} is outside its bound");
    }
    Ok((sha256_path(path)?, bytes))
}

fn validate_completed_artifacts(
    report_path: &Path,
    dump_path: &Path,
    nonce: &str,
) -> Result<BootstrapHangArtifactReference> {
    let report_bytes = read_bounded_regular_file(report_path, MAX_BOOTSTRAP_HANG_REPORT_BYTES)?;
    let report: BootstrapHangDiagnosticReport = serde_json::from_slice(&report_bytes)?;
    report.validate(nonce)?;
    if report.dump_name != file_name(dump_path)? {
        bail!("bootstrap hang report named a different minidump");
    }
    let dump_metadata = fs::symlink_metadata(dump_path)?;
    if !dump_metadata.file_type().is_file()
        || dump_metadata.len() == 0
        || dump_metadata.len() > MAX_BOOTSTRAP_HANG_DUMP_BYTES
    {
        bail!("bootstrap minidump is not one bounded regular file");
    }
    let dump_sha256 = sha256_path(dump_path)?;
    if report.dump_bytes != dump_metadata.len() || report.dump_sha256 != dump_sha256 {
        bail!("bootstrap minidump identity changed after capture");
    }
    let reference = BootstrapHangArtifactReference {
        report_name: file_name(report_path)?,
        report_sha256: sha256_bytes(&report_bytes),
        report_bytes: u64::try_from(report_bytes.len())?,
        dump_name: report.dump_name,
        dump_sha256,
        dump_bytes: dump_metadata.len(),
    };
    reference.validate()?;
    Ok(reference)
}

fn read_helper_failure(path: &Path, nonce: &str) -> Result<String> {
    let bytes = read_bounded_regular_file(path, MAX_BOOTSTRAP_HANG_REPORT_BYTES)?;
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    if value.get("schema_version").and_then(serde_json::Value::as_u64) != Some(1)
        || value.get("nonce").and_then(serde_json::Value::as_str) != Some(nonce)
        || value.get("captured").and_then(serde_json::Value::as_bool) != Some(false)
    {
        bail!("diagnostic helper failure record identity is invalid");
    }
    value
        .get("error")
        .and_then(serde_json::Value::as_str)
        .map(|value| bounded_text(value, 2_048))
        .context("diagnostic helper failure record omitted its error")
}

fn wait_for_helper(process: &OwnedHandle, timeout: Duration) -> Result<()> {
    let milliseconds = u32::try_from(timeout.as_millis().clamp(1, u128::from(u32::MAX)))?;
    match unsafe { WaitForSingleObject(process.0, milliseconds) } {
        WAIT_OBJECT_0 => Ok(()),
        WAIT_TIMEOUT => {
            let _ = unsafe { TerminateProcess(process.0, 125) };
            let _ = unsafe { WaitForSingleObject(process.0, u32::MAX) };
            bail!("trusted hang diagnostic helper exceeded its hard deadline")
        }
        _ => {
            Err(std::io::Error::last_os_error()).context("wait for trusted hang diagnostic helper")
        }
    }
}

fn duplicate_into_process(source: HANDLE, process: HANDLE, name: &str) -> Result<HANDLE> {
    let mut duplicated = null_mut();
    check(
        unsafe {
            DuplicateHandle(
                GetCurrentProcess(),
                source,
                process,
                &mut duplicated,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        },
        &format!("duplicate {name} into diagnostic helper"),
    )?;
    Ok(duplicated)
}

fn owned_remote_handle(value: u64, name: &str) -> Result<OwnedHandle> {
    let value = usize::try_from(value)? as *mut c_void;
    if value.is_null() || value == INVALID_HANDLE_VALUE {
        bail!("{name} handle is invalid");
    }
    Ok(OwnedHandle(value))
}

fn validate_new_artifact_path(path: &Path, fixture_root: &Path) -> Result<()> {
    if path.parent() != Some(fixture_root) {
        bail!("bootstrap hang artifact escaped the canonical fixture root");
    }
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(_) => bail!("bootstrap hang artifact path already exists"),
        Err(error) => {
            Err(error).with_context(|| format!("inspect artifact path {}", path.display()))
        }
    }
}

fn read_bounded_regular_file(path: &Path, maximum: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > maximum {
        bail!("{} is not one bounded regular file", path.display());
    }
    fs::read(path).with_context(|| format!("read bounded artifact {}", path.display()))
}

fn write_create_new(path: &Path, bytes: &[u8], maximum: u64) -> Result<()> {
    if bytes.is_empty() || u64::try_from(bytes.len())? > maximum {
        bail!("artifact payload is outside its bound");
    }
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.flush()?;
    Ok(())
}

fn verify_sha256(path: &Path, expected: &str, name: &str) -> Result<()> {
    let observed = sha256_path(path)?;
    if observed != expected {
        bail!("{name} SHA-256 mismatch: expected {expected}, observed {observed}");
    }
    Ok(())
}

fn sha256_path(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn sha256_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn file_name(path: &Path) -> Result<String> {
    path.file_name()
        .and_then(|value| value.to_str())
        .map(str::to_owned)
        .context("bootstrap hang artifact name is not portable UTF-8")
}

fn validate_nonce(nonce: &str) -> Result<()> {
    if nonce.len() != 64 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("bootstrap hang diagnostic nonce is invalid");
    }
    Ok(())
}

fn filtered_helper_environment_block() -> Vec<u16> {
    let mut values = std::env::vars_os()
        .filter_map(|(key, value)| {
            let key = key.to_string_lossy();
            (!key.to_ascii_uppercase().starts_with("CMUX_BENCH_"))
                .then(|| format!("{key}={}", value.to_string_lossy()))
        })
        .collect::<Vec<_>>();
    values.sort_by_key(|value| value.to_ascii_uppercase());
    encode_environment_block(values)
}

fn cmux_bench_environment_is_filtered(block: &[u16], allowed: &[&str]) -> bool {
    block
        .split(|value| *value == 0)
        .take_while(|value| !value.is_empty())
        .filter_map(|value| String::from_utf16(value).ok())
        .filter_map(|value| value.split_once('=').map(|(key, _)| key.to_owned()))
        .all(|key| {
            !key.to_ascii_uppercase().starts_with("CMUX_BENCH_")
                || allowed.iter().any(|allowed| key.eq_ignore_ascii_case(allowed))
        })
}

fn encode_environment_block(values: Vec<String>) -> Vec<u16> {
    let mut block = Vec::new();
    for value in values {
        block.extend(OsStr::new(&value).encode_wide());
        block.push(0);
    }
    block.push(0);
    block
}

fn utf16_z(value: &[u16]) -> String {
    let end = value.iter().position(|item| *item == 0).unwrap_or(value.len());
    String::from_utf16_lossy(&value[..end])
}

fn bounded_text(value: &str, maximum: usize) -> String {
    if value.len() <= maximum {
        return value.to_owned();
    }
    let mut end = maximum;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &value[..end])
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
            '\"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('\"');
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
    quoted.push('\"');
    quoted
}

fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(Some(0)).collect()
}

fn check(value: i32, operation: &str) -> Result<()> {
    if value == 0 {
        return Err(std::io::Error::last_os_error()).context(operation.to_owned());
    }
    Ok(())
}

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe { CloseHandle(self.0) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_environment_rejects_all_benchmark_values() {
        let filtered =
            encode_environment_block(vec!["PATH=C:\\Windows".into(), "TEMP=C:\\fixture".into()]);
        let leaked = encode_environment_block(vec![
            "PATH=C:\\Windows".into(),
            "CMUX_BENCH_WINDOWS_PASSWORD=secret".into(),
        ]);

        assert!(cmux_bench_environment_is_filtered(&filtered, &[]));
        assert!(!cmux_bench_environment_is_filtered(&leaked, &[]));
    }

    #[test]
    fn helper_invocation_requires_both_nonces_and_bounded_names() {
        let nonce = "ab".repeat(32);
        let values = vec![
            "--config".into(),
            r"C:\fixture\config.json".into(),
            "--nonce".into(),
            nonce.clone(),
            "--helper-nonce".into(),
            nonce,
            "--output".into(),
            r"C:\fixture\report.json".into(),
        ];

        let parsed = parse_helper_invocation(&values).unwrap();
        assert_eq!(parsed.config_path, PathBuf::from(r"C:\fixture\config.json"));

        let mut missing_helper_nonce = values;
        missing_helper_nonce.drain(4..6);
        assert!(parse_helper_invocation(&missing_helper_nonce).is_err());
    }
}
