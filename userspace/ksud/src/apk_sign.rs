use std::io::{Read, Seek, SeekFrom};

use anyhow::{Result, ensure};

pub fn get_apk_signature(apk: &str) -> Result<(u32, String)> {
    let mut buffer = [0u8; 0x10];
    let mut size4 = [0u8; 4];
    let mut size8 = [0u8; 8];
    let mut size_of_block = [0u8; 8];

    let mut f = std::fs::File::open(apk)?;

    let mut i = 0;
    loop {
        let mut n = [0u8; 2];
        f.seek(SeekFrom::End(-i - 2))?;
        f.read_exact(&mut n)?;

        let n = u16::from_le_bytes(n);
        if i64::from(n) == i {
            f.seek(SeekFrom::Current(-22))?;
            f.read_exact(&mut size4)?;

            if u32::from_le_bytes(size4) ^ 0xcafe_babe_u32 == 0xccfb_f1ee_u32 {
                if i > 0 {
                    println!("warning: comment length is {i}");
                }
                break;
            }
        }

        ensure!(i < 0xffff, "not a zip file");

        i += 1;
    }

    f.seek(SeekFrom::Current(12))?;
    // offset
    f.read_exact(&mut size4)?;
    // central directory offset: the signing block (and its last pair) ends 0x18 bytes before it
    let cd_offset = u64::from(u32::from_le_bytes(size4));
    let block_footer = cd_offset
        .checked_sub(0x18)
        .ok_or_else(|| anyhow::anyhow!("Can not found sig block"))?;
    f.seek(SeekFrom::Start(block_footer))?;

    f.read_exact(&mut size8)?;
    f.read_exact(&mut buffer)?;

    ensure!(&buffer == b"APK Sig Block 42", "Can not found sig block");

    let pos = u64::from_le_bytes(size8)
        .checked_add(0x8)
        .and_then(|len| cd_offset.checked_sub(len))
        .ok_or_else(|| anyhow::anyhow!("not a signed apk"))?;
    f.seek(SeekFrom::Start(pos))?;
    f.read_exact(&mut size_of_block)?;

    ensure!(size_of_block == size8, "not a signed apk");

    let mut v2_signing: Option<(u32, String)> = None;
    let mut v3_signing_exist = false;
    let mut v3_1_signing_exist = false;

    loop {
        let mut id = [0u8; 4];

        f.read_exact(&mut size8)?; // sequence length
        if size8 == size_of_block {
            break;
        }
        // a pair holds at least its id and ends inside the block (as kernel/manager/apk_sign.c)
        let pair_len = u64::from_le_bytes(size8);
        let pair_end = f
            .stream_position()?
            .checked_add(pair_len)
            .filter(|&end| pair_len >= 4 && end <= block_footer)
            .ok_or_else(|| anyhow::anyhow!("invalid APK signing block pair"))?;

        f.read_exact(&mut id)?; // id

        let id = u32::from_le_bytes(id);
        if id == 0x7109_871a_u32 {
            v2_signing = Some(calc_cert_sha256(&mut f, &mut size4, pair_len)?);
        } else if id == 0xf053_68c0_u32 {
            // v3 signature scheme
            v3_signing_exist = true;
        } else if id == 0x1b93_ad61_u32 {
            // v3.1 signature scheme: credits to vvb2060
            v3_1_signing_exist = true;
        }

        f.seek(SeekFrom::Start(pair_end))?;
    }

    if v3_signing_exist || v3_1_signing_exist {
        return Err(anyhow::anyhow!("Unexpected v3 signature found!"));
    }

    v2_signing.ok_or_else(|| anyhow::anyhow!("No signature found!"))
}

fn calc_cert_sha256(
    f: &mut std::fs::File,
    size4: &mut [u8; 4],
    pair_len: u64,
) -> Result<(u32, String)> {
    f.read_exact(size4)?; // signer-sequence length
    f.read_exact(size4)?; // signer length
    f.read_exact(size4)?; // signed data length

    f.read_exact(size4)?; // digests-sequence length
    let pos = u32::from_le_bytes(*size4); // skip digests
    f.seek(SeekFrom::Current(i64::from(pos)))?;

    f.read_exact(size4)?; // certificates length
    f.read_exact(size4)?; // certificate length

    let cert_len = u32::from_le_bytes(*size4);
    ensure!(
        u64::from(cert_len) <= pair_len,
        "invalid certificate length"
    );
    let mut cert: Vec<u8> = vec![0; cert_len as usize];
    f.read_exact(&mut cert)?;

    Ok((cert_len, sha256::digest(&cert)))
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::get_apk_signature;

    fn lp(b: &[u8]) -> Vec<u8> {
        let mut v = u32::try_from(b.len()).unwrap().to_le_bytes().to_vec();
        v.extend_from_slice(b);
        v
    }

    /// A file with one signing block pair (`pair_len` overrides its length field), an empty
    /// central directory and an end of central directory record pointing at `cd_offset`
    /// (default: the real one).
    fn apk(cert: &[u8], pair_len: Option<u64>, cd_offset: Option<u32>) -> tempfile::NamedTempFile {
        let digests = lp(&lp(&[0u8; 8]));
        let mut signed_data = digests;
        signed_data.extend(lp(&lp(cert)));
        signed_data.extend(lp(&[]));
        let mut signer = lp(&signed_data);
        signer.extend(lp(&[]));
        signer.extend(lp(&[]));
        let value = lp(&lp(&signer));
        let len = 4 + value.len() as u64;
        let mut pairs = pair_len.unwrap_or(len).to_le_bytes().to_vec();
        pairs.extend(0x7109_871a_u32.to_le_bytes());
        pairs.extend(value);
        let block_size = (pairs.len() + 8 + 16) as u64;
        let mut data = block_size.to_le_bytes().to_vec();
        data.extend(pairs);
        data.extend(block_size.to_le_bytes());
        data.extend(b"APK Sig Block 42");
        let cd = cd_offset.unwrap_or(u32::try_from(data.len()).unwrap());
        data.extend(0x0605_4b50_u32.to_le_bytes());
        data.extend([0u8; 12]);
        data.extend(cd.to_le_bytes());
        data.extend([0u8; 2]);
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(&data).unwrap();
        f
    }

    fn sign_of(f: &tempfile::NamedTempFile) -> anyhow::Result<(u32, String)> {
        get_apk_signature(f.path().to_str().unwrap())
    }

    #[test]
    fn reads_first_v2_certificate() {
        let cert: Vec<u8> = (0..735u32).map(|i| (i * 7 + 3) as u8).collect();
        let (size, hash) = sign_of(&apk(&cert, None, None)).unwrap();
        assert_eq!(size, 735);
        assert_eq!(hash, sha256::digest(&cert));
    }

    #[test]
    fn rejects_pair_length_that_points_backwards() {
        // -8: the old loop sought back to the same pair forever
        assert!(sign_of(&apk(&[1u8; 16], Some(u64::MAX - 7), None)).is_err());
    }

    #[test]
    fn rejects_pair_longer_than_the_block() {
        assert!(sign_of(&apk(&[1u8; 16], Some(1 << 20), None)).is_err());
    }

    #[test]
    fn rejects_central_directory_offset_inside_the_header() {
        assert!(sign_of(&apk(&[1u8; 16], None, Some(4))).is_err());
    }
}
