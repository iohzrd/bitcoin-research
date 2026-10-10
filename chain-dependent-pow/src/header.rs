//! The chain's version 2 header, ported from ~/src/bitcoin src/primitives/block.{h,cpp}: the
//! 164-byte wire form, `GetPowStages` (the stage-3 digest `hash2` and the XOR `mask`), the block
//! hash (`MaskAndReverse`), and the `nBits` target. Checked against the node's
//! src/test/data/block_header_v2.json.

use sha2::{Digest, Sha256};

pub type Hash = [u8; 32];

pub const V2_FLAG: u32 = 0x8000_0000;
pub const SIZE: usize = 164;

/// Wire fields in serialization order. `version` includes `V2_FLAG`; `time` is the wire time
/// (`GetTimeOnWire`), which is what the hash stages use. Hashes are in internal byte order.
#[derive(Clone, Debug, PartialEq)]
pub struct V2Header {
    pub version: u32,
    pub prev: Hash,
    pub merkle: Hash,
    pub time: u32,
    pub bits: u32,
    pub nonce: u32,
    pub nonce2: u32,
    pub nonce3: u32,
    pub extranonce: [u8; 16],
    pub time_offset: u32,
    pub txcount: u16,
    pub flags: u8,
    pub mask_clear_bits: u8,
    pub xor_key: [u8; 16],
    pub height: i32,
    pub mm_rhs: Hash,
}

fn sha256(parts: &[&[u8]]) -> Hash {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

/// `TaggedHash(tag) << data`, finished with `GetSHA256`: SHA-256(SHA-256(tag) || SHA-256(tag) || data).
fn tagged(tag: &str, parts: &[&[u8]]) -> Hash {
    let t = sha256(&[tag.as_bytes()]);
    let mut all: Vec<&[u8]> = vec![&t, &t];
    all.extend_from_slice(parts);
    sha256(&all)
}

fn blake2b(data: &[u8]) -> Hash {
    super::blake2b(&[data])
}

fn rev(h: &Hash) -> Hash {
    let mut r = *h;
    r.reverse();
    r
}

impl V2Header {
    pub fn serialize(&self) -> [u8; SIZE] {
        let v: Vec<u8> = [
            &self.version.to_le_bytes()[..],
            &self.prev,
            &self.merkle,
            &self.time.to_le_bytes(),
            &self.bits.to_le_bytes(),
            &self.nonce.to_le_bytes(),
            &self.nonce2.to_le_bytes(),
            &self.nonce3.to_le_bytes(),
            &self.extranonce,
            &self.time_offset.to_le_bytes(),
            &self.txcount.to_le_bytes(),
            &[self.flags, self.mask_clear_bits],
            &self.xor_key,
            &self.height.to_le_bytes(),
            &self.mm_rhs,
        ]
        .concat();
        v.try_into().unwrap()
    }

    #[cfg(test)]
    pub fn parse(b: &[u8; SIZE]) -> Self {
        let mut at = 0;
        let mut take = |n: usize| {
            at += n;
            &b[at - n..at]
        };
        let u32_ = |s: &[u8]| u32::from_le_bytes(s.try_into().unwrap());
        let version = u32_(take(4));
        assert!(version & V2_FLAG != 0, "not a v2 header");
        V2Header {
            version,
            prev: take(32).try_into().unwrap(),
            merkle: take(32).try_into().unwrap(),
            time: u32_(take(4)),
            bits: u32_(take(4)),
            nonce: u32_(take(4)),
            nonce2: u32_(take(4)),
            nonce3: u32_(take(4)),
            extranonce: take(16).try_into().unwrap(),
            time_offset: u32_(take(4)),
            txcount: u16::from_le_bytes(take(2).try_into().unwrap()),
            flags: take(1)[0],
            mask_clear_bits: take(1)[0],
            xor_key: take(16).try_into().unwrap(),
            height: i32::from_le_bytes(take(4).try_into().unwrap()),
            mm_rhs: take(32).try_into().unwrap(),
        }
    }

    /// `GetPowStages`: (hash2, mask), with the intermediate stages for the test vectors.
    pub fn stages(&self) -> Stages {
        let xor_key_hash = tagged("Bitcoin block hash PoW XOR key", &[&self.xor_key]);
        let mut mask = [0u8; 32];
        if self.xor_key != [0; 16] {
            mask = tagged("Bitcoin block hash PoW XOR mask", &[&self.xor_key]);
            let clear = (self.mask_clear_bits / 8) as usize;
            mask[..clear].fill(0);
            mask[clear] &= 0xff >> (self.mask_clear_bits % 8);
        }
        let prev_sane = rev(&self.prev);
        let mut prev_hidden = tagged("Bitcoin prevblock header, hashed", &[&prev_sane]);
        let h1 = tagged(
            "Bitcoin block header 1",
            &[
                &self.version.to_le_bytes(),
                &prev_sane,
                &self.height.to_le_bytes(),
                &self.merkle,
                &self.time.to_le_bytes(),
                &[0],
                &self.bits.to_le_bytes(),
                &(self.txcount as u32).to_le_bytes(),
                &[self.flags, self.mask_clear_bits],
                &xor_key_hash,
            ],
        );
        let h2 = tagged("Merge-mining hook", &[&h1, &[0; 32], &self.mm_rhs]);
        let b1 = blake2b(&[&[0u8; 4][..], &h2, &self.extranonce].concat());
        let (n1, n2, n3, to) = (self.nonce.to_le_bytes(), self.nonce2.to_le_bytes(), self.nonce3.to_le_bytes(), self.time_offset.to_le_bytes());
        let asic_input: Vec<u8> = match self.flags & 3 {
            3 => [&[0u8; 80][..], &h2, &n1, &n2, &to, &n3, &b1].concat(),
            2 => [&[0u8; 48][..], &h2, &n1, &n2, &to, &n3, &b1].concat(),
            0 => {
                prev_hidden[..6].fill(0);
                [&prev_hidden[..], &n1, &n2, &to, &n3, &b1].concat()
            }
            _ => [&n1[..], &n2, &n3, &to, &b1, &h2].concat(),
        };
        let hash2 = blake2b(&asic_input);
        Stages { xor_key_hash, h1, h2, blake2b_1: b1, hash2, mask, asic_input }
    }

    /// Block hash in display order (`GetHex`): hash2 XOR mask.
    pub fn block_hash(&self) -> Hash {
        let s = self.stages();
        xor(&s.hash2, &s.mask)
    }
}

/// Intermediate stages are kept for the node's test vectors.
#[cfg_attr(not(test), allow(dead_code))]
pub struct Stages {
    pub xor_key_hash: Hash,
    pub h1: Hash,
    pub h2: Hash,
    pub blake2b_1: Hash,
    pub hash2: Hash,
    pub mask: Hash,
    pub asic_input: Vec<u8>,
}

pub fn xor(a: &Hash, b: &Hash) -> Hash {
    std::array::from_fn(|i| a[i] ^ b[i])
}

/// The target of compact `bits`, big-endian (display order); None if negative or overflowing.
pub fn target(bits: u32) -> Option<Hash> {
    let exp = (bits >> 24) as usize;
    let mant = bits & 0x007f_ffff;
    if bits & 0x0080_0000 != 0 && mant != 0 {
        return None;
    }
    let mut t = [0u8; 32];
    let m = mant.to_be_bytes(); // [0, b2, b1, b0]
    for (i, &byte) in m[1..].iter().enumerate() {
        // Byte i of the mantissa (most significant first) sits at power 256^(exp - 1 - i).
        let power = exp as isize - 1 - i as isize;
        if power < 0 {
            continue;
        }
        if power >= 32 {
            if byte != 0 {
                return None;
            }
            continue;
        }
        t[31 - power as usize] = byte;
    }
    Some(t)
}

/// Whether `digest` XOR `mask`, read as a block hash, is at or below the target of `bits`.
/// Display order is the XOR's own byte order, so it compares as a big-endian number.
pub fn meets(digest: &Hash, mask: &Hash, bits: u32) -> bool {
    target(bits).is_some_and(|t| xor(digest, mask) <= t)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn node_v2_vectors() {
        let data: serde_json::Value = serde_json::from_str(include_str!("../testdata/block_header_v2.json")).unwrap();
        let headers = data["headers"].as_array().unwrap();
        assert_eq!(headers.len(), 5);
        for t in headers {
            let wire: [u8; SIZE] = unhex(t["serialized"].as_str().unwrap()).try_into().unwrap();
            let h = V2Header::parse(&wire);
            assert_eq!(h.serialize(), wire);
            assert_eq!(h.flags & 3, t["asic_profile"].as_u64().unwrap() as u8);
            let s = h.stages();
            let name = t["name"].as_str().unwrap();
            for (key, got) in [
                ("xor_key_hash", &s.xor_key_hash),
                ("h1", &s.h1),
                ("h2", &s.h2),
                ("blake2b_1", &s.blake2b_1),
                ("blake2b_2", &s.hash2),
                ("mask", &s.mask),
                ("block_hash", &h.block_hash()),
            ] {
                assert_eq!(hex(got), t[key].as_str().unwrap(), "{name}: {key}");
            }
            assert_eq!(hex(&s.asic_input), t["asic_input"].as_str().unwrap(), "{name}: asic_input");
        }
    }

    #[test]
    fn compact_targets() {
        // 0x1d00ffff: 0x00000000ffff0000...
        let t = target(0x1d00_ffff).unwrap();
        assert_eq!(hex(&t[..8]), "00000000ffff0000");
        assert!(t[8..].iter().all(|&b| b == 0));
        // 0x207fffff (regtest): 0x7fffff00...
        assert_eq!(hex(&target(0x207f_ffff).unwrap()[..4]), "7fffff00");
        // 0x03123456: 0x123456 in the last three bytes.
        assert_eq!(hex(&target(0x0312_3456).unwrap()[29..]), "123456");
        assert_eq!(target(0x0180_0001), None);
    }
}
