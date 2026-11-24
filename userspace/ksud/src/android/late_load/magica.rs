use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    process::Command,
};

use adb_client::{ADBDeviceExt, tcp::ADBTcpDevice};
use anyhow::{Context, Result, bail};
use log::{error, info};
use prop_rs_android::{resetprop::ResetProp, sys_prop};

const fn resetprop() -> ResetProp {
    ResetProp {
        skip_svc: true,
        persistent: false,
        persist_only: false,
        verbose: false,
        show_context: false,
        rebuild: false,
    }
}

fn exec_shell_commands(commands: &[(&str, &[&str])], log_prefix: &str) -> Result<()> {
    for (cmd, args) in commands {
        info!("{log_prefix}: {cmd} {}", args.join(" "));
        let status = Command::new(cmd)
            .args(*args)
            .status()
            .with_context(|| format!("Failed to execute {cmd}"))?;
        if !status.success() {
            bail!("{cmd} {} exited with {status}", args.join(" "));
        }
    }
    Ok(())
}

fn enable_adb_root(port: u16) -> Result<()> {
    // We are in limited root by magica
    anyhow::ensure!(
        rustix::process::getuid().as_raw() == 0,
        "must be run as root"
    );

    sys_prop::init().context("Failed to initialize system property API")?;
    let rp = resetprop();

    let debuggable_context = sys_prop::get_context("ro.debuggable")
        .context("Failed to get context for ro.debuggable")?;
    info!("ro.debuggable context: {debuggable_context}");

    let adb_secure_context = sys_prop::get_context("ro.adb.secure")
        .context("Failed to get context for ro.adb.secure")?;
    info!("ro.adb.secure context: {adb_secure_context}");

    let props_serial = "/dev/__properties__/properties_serial";
    let debuggable_context = format!("/dev/__properties__/{debuggable_context}");
    let adb_secure_context = format!("/dev/__properties__/{adb_secure_context}");
    let port_str = port.to_string();

    // chmod property files to writable
    exec_shell_commands(
        &[
            ("chmod", &["0644", props_serial]),
            ("chmod", &["0644", &debuggable_context]),
            ("chmod", &["0644", &adb_secure_context]),
        ],
        "Executing",
    )?;

    // Set properties via internal API
    let mut debuggable_set = false;
    let set = (|| -> Result<()> {
        rp.set("ro.debuggable", "1")
            .context("Failed to set ro.debuggable")?;
        debuggable_set = true;
        info!("Executing: resetprop -n ro.debuggable 1");
        rp.set("ro.adb.secure", "0")
            .context("Failed to set ro.adb.secure")?;
        info!("Executing: resetprop -n ro.adb.secure 0");
        Ok(())
    })();
    if let Err(e) = set {
        // do not leave ro.debuggable set or the property files writable
        if debuggable_set {
            let _ = rp.set("ro.debuggable", "0");
        }
        let _ = exec_shell_commands(
            &[
                ("chmod", &["0444", props_serial]),
                ("chmod", &["0444", &debuggable_context]),
                ("chmod", &["0444", &adb_secure_context]),
            ],
            "Restoring",
        );
        return Err(e);
    }

    // Restore permissions and restart adbd
    exec_shell_commands(
        &[
            ("chmod", &["0444", props_serial]),
            ("chmod", &["0444", &debuggable_context]),
            ("chmod", &["0444", &adb_secure_context]),
            ("setprop", &["service.adb.root", "1"]),
            ("setprop", &["service.adb.tcp.port", &port_str]),
            ("setprop", &["ctl.restart", "adbd"]),
        ],
        "Executing",
    )?;

    Ok(())
}

pub fn disable_adb_root() -> Result<()> {
    // We have full root now, no need to chmod
    sys_prop::init().context("Failed to initialize system property API")?;
    let rp = resetprop();

    info!("Restoring: resetprop -n ro.debuggable 0");
    rp.set("ro.debuggable", "0")
        .context("Failed to set ro.debuggable")?;

    info!("Restoring: resetprop -n ro.adb.secure 1");
    rp.set("ro.adb.secure", "1")
        .context("Failed to set ro.adb.secure")?;

    for prop in &[
        "service.adb.root",
        "service.adb.tcp.port",
        "ro.boot.selinux",
    ] {
        info!("Restoring: resetprop --delete {prop}");
        let _ = rp.delete(prop);
        if let Ok(ctx) = sys_prop::get_context(prop) {
            let _ = rp.rebuild(&ctx);
        }
    }

    exec_shell_commands(&[("setprop", &["ctl.restart", "adbd"])], "Restoring")?;

    Ok(())
}

fn connect_to_device(port: u16) -> Result<ADBTcpDevice> {
    const MAX_RETRIES: u32 = 30;
    for attempt in 1..=MAX_RETRIES {
        info!("Waiting for adbd to restart... (attempt {attempt}/{MAX_RETRIES})");
        std::thread::sleep(std::time::Duration::from_secs(1));

        let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        info!("Connecting to ADB device at {addr}");
        match ADBTcpDevice::new(addr).context("Failed to create ADBTcpDevice") {
            Ok(device) => return Ok(device),
            Err(e) => {
                error!("Failed to connect to ADB device: {e:?}, retry after 1s");
            }
        }
    }
    bail!("Failed to connect to ADB device after {MAX_RETRIES} attempts")
}

/// The parent's best-effort undo of enable_adb_root when the post-magica child never ran (it
/// restores the props itself): property files writable, props restored, files read-only again.
fn restore_adb_props() {
    let files = ["ro.debuggable", "ro.adb.secure"]
        .map(|prop| sys_prop::get_context(prop).map(|ctx| format!("/dev/__properties__/{ctx}")));
    let mut paths = vec!["/dev/__properties__/properties_serial".to_string()];
    paths.extend(files.into_iter().flatten());
    let chmod = |mode: &str| {
        for path in &paths {
            if let Err(e) = exec_shell_commands(&[("chmod", &[mode, path.as_str()])], "Restoring") {
                error!("{e}");
            }
        }
    };
    chmod("0644");
    if let Err(e) = disable_adb_root() {
        error!("disable adb root failed: {e}");
    }
    chmod("0444");
}

pub fn run(port: u16, package_name: &String, allow_shell: bool) -> Result<()> {
    enable_adb_root(port)?;

    let mut device = connect_to_device(port).inspect_err(|_| restore_adb_props())?;

    let self_path = std::env::current_exe().context("Failed to get self exe path")?;

    // Execute late-load with --post-magica via adb shell.
    // The late-load process has full root + su domain and will:
    // 1. Load kernelsu.ko, enforce SELinux, run stage scripts
    // 2. Restore adb properties (disable adb root/tcp mode)
    let allow_shell_arg = if allow_shell { " --allow-shell" } else { "" };
    // adb shell reports no exit status: the remote shell prints it after the command
    let cmd = format!(
        "{} late-load --post-magica --package-name {}{}; echo {EXIT_MARKER}$?",
        self_path.display(),
        package_name,
        allow_shell_arg
    );
    info!("Executing '{cmd}' via adb shell...");
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let shell = device.shell_command(&cmd, Some(&mut stdout), Some(&mut stderr));
    if let Err(e) = &shell {
        info!("adb shell finished with error (may be expected): {e}");
    }
    if !stdout.is_empty() {
        info!("stdout: {}", String::from_utf8_lossy(&stdout));
    }
    if !stderr.is_empty() {
        info!("stderr: {}", String::from_utf8_lossy(&stderr));
    }

    // the post-magica child restores the adb props; when it did not start, do it here
    match post_magica_status(&String::from_utf8_lossy(&stdout)) {
        Some(0) => Ok(()),
        // the connection may drop when the child restarts adbd: its status is then unknown
        None if shell.is_err() => Ok(()),
        status => {
            restore_adb_props();
            bail!("late-load --post-magica did not start (exit status {status:?})")
        }
    }
}

const EXIT_MARKER: &str = "ksud-post-magica-exit:";

/// Exit status printed by the remote shell after `late-load --post-magica`, if any.
fn post_magica_status(stdout: &str) -> Option<i32> {
    stdout
        .lines()
        .rev()
        .find_map(|line| line.trim().strip_prefix(EXIT_MARKER))
        .and_then(|code| code.parse().ok())
}
