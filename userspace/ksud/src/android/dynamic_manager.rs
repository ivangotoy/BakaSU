use std::fs;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::{android::ksucalls, defs};

#[derive(Debug, Deserialize, Serialize)]
struct Config {
    size: u32,
    hash: String,
}

impl Config {
    fn hash_bytes(&self) -> Result<[u8; 64], String> {
        parse_hash(&self.hash)
    }

    pub fn set_hash_from_bytes(&mut self, hash: [u8; 64]) {
        self.hash = String::from_utf8_lossy(&hash).to_string();
    }
}

pub fn booted_load() -> Result<()> {
    let buf = match fs::read_to_string(defs::DYNAMIC_MANAGER) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };

    let json: Config = serde_json::from_str(&buf)?;
    if json.hash.is_empty() || json.size == 0 {
        return Ok(());
    }
    let Ok(hash) = json.hash_bytes() else {
        return Ok(());
    };

    ksucalls::dynamic_manager_set(json.size, hash)?;
    Ok(())
}

pub fn parse_hash(s: &str) -> Result<[u8; 64], String> {
    s.as_bytes()
        .try_into()
        .map_err(|_| "Incorrect hash".to_string())
}

pub fn clear() -> Result<()> {
    let empty = Config {
        size: 0,
        hash: String::new(),
    };

    let string = serde_json::to_string_pretty(&empty)?;

    ksucalls::dynamic_manager_clear()?;

    write_config(&string)
}

pub fn set(size: u32, hash: [u8; 64]) -> Result<()> {
    let mut json_raw = Config {
        size,
        hash: String::new(),
    };
    json_raw.set_hash_from_bytes(hash);

    let string = serde_json::to_string_pretty(&json_raw)?;

    ksucalls::dynamic_manager_set_synchronous(size, hash)?;

    write_config(&string)
}

/// Persist only what the kernel accepted (booted_load re-applies the file at every boot), and
/// replace the file atomically: a truncated file would lose the manager at the next boot.
fn write_config(content: &str) -> Result<()> {
    let tmp = format!("{}.tmp", defs::DYNAMIC_MANAGER);
    fs::write(&tmp, content)
        .and_then(|()| fs::rename(&tmp, defs::DYNAMIC_MANAGER))
        .inspect_err(|_| {
            let _ = fs::remove_file(&tmp);
        })?;
    Ok(())
}
