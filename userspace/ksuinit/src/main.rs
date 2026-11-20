#![no_main]

mod init;

use rustix::{cstr, runtime::execve};
/// # Safety
/// This is the entry point of the program
/// We cannot use the main because rust will abort if we don't have std{in/out/err}
/// https://github.com/rust-lang/rust/blob/3071aefdb2821439e2e6f592f41a4d28e40c1e79/library/std/src/sys/unix/mod.rs#L80
/// So we use the C main function and call rust code from there
#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(_argc: i32, argv: *const *const u8, envp: *const *const u8) -> i32 {
    let swapped = match init::init() {
        Ok(()) => true,
        Err(e) => {
            log::error!("ksuinit failed: {e:?}");
            false
        }
    };
    // /init is the real init only when the swap above completed; otherwise (and if exec of
    // /init fails) exec the real init directly. PID 1 must never return.
    let targets = [
        cstr!("/init"),
        cstr!("/init.real"),
        cstr!("/system/bin/init"),
    ];
    for target in &targets[usize::from(!swapped)..] {
        let err = unsafe { execve(target, argv, envp) };
        log::error!("Cannot exec {target:?}: {err}");
    }
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
