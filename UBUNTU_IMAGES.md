# Ubuntu Cloud Images Location

## Official Ubuntu Cloud Images Repository

Ubuntu cloud images are hosted at: **https://cloud-images.ubuntu.com/**

## URL Structure

Ubuntu provides cloud images in two formats:

### 1. By Codename (Recommended)
**URL Pattern:** `https://cloud-images.ubuntu.com/{codename}/current/`

**Examples:**
- **Ubuntu 24.04 LTS (Noble)**: `https://cloud-images.ubuntu.com/noble/current/`
- **Ubuntu 22.04 LTS (Jammy)**: `https://cloud-images.ubuntu.com/jammy/current/`
- **Ubuntu 20.04 LTS (Focal)**: `https://cloud-images.ubuntu.com/focal/current/`
- **Ubuntu 18.04 LTS (Bionic)**: `https://cloud-images.ubuntu.com/bionic/current/`

### 2. By Version Number
**URL Pattern:** `https://cloud-images.ubuntu.com/releases/{version}/release/`

**Examples:**
- **Ubuntu 24.04**: `https://cloud-images.ubuntu.com/releases/24.04/release/`
- **Ubuntu 22.04**: `https://cloud-images.ubuntu.com/releases/22.04/release/`
- **Ubuntu 20.04**: `https://cloud-images.ubuntu.com/releases/20.04/release/`

## Image Naming Convention

Ubuntu cloud images follow this naming pattern (using codenames):
- `{codename}-server-cloudimg-amd64.img` (QCOW2 format, standard)
- `{codename}-server-cloudimg-amd64-disk-kvm.img` (QCOW2 format, KVM optimized - **recommended for KVM/libvirt**)

**Note:** Ubuntu images use `.img` extension but are actually QCOW2 format files.

**Example filenames:**
- `noble-server-cloudimg-amd64.img` (Ubuntu 24.04)
- `noble-server-cloudimg-amd64-disk-kvm.img` (Ubuntu 24.04, KVM optimized)
- `jammy-server-cloudimg-amd64.img` (Ubuntu 22.04)
- `jammy-server-cloudimg-amd64-disk-kvm.img` (Ubuntu 22.04, KVM optimized)
- `focal-server-cloudimg-amd64.img` (Ubuntu 20.04)
- `focal-server-cloudimg-amd64-disk-kvm.img` (Ubuntu 20.04, KVM optimized)

## Comparison with Other Distributions

| Distribution | Base URL | Example |
|--------------|----------|---------|
| **Fedora** | `https://download.fedoraproject.org/pub/fedora/linux/releases/{version}/Cloud/x86_64/images/` | `https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/` |
| **Debian** | `https://cloud.debian.org/images/cloud/{codename}/latest/` | `https://cloud.debian.org/images/cloud/bookworm/latest/` |
| **Ubuntu** | `https://cloud-images.ubuntu.com/{codename}/current/` | `https://cloud-images.ubuntu.com/jammy/current/` |

## Ubuntu Version to Codename Mapping

| Version | Codename | LTS | Status |
|---------|----------|-----|--------|
| 24.04 | Noble Numbat | Yes | Current LTS |
| 23.10 | Mantic Minotaur | No | EOL |
| 23.04 | Lunar Lobster | No | EOL |
| 22.04 | Jammy Jellyfish | Yes | LTS (supported until 2027) |
| 20.04 | Focal Fossa | Yes | LTS (supported until 2025) |
| 18.04 | Bionic Beaver | Yes | EOL (was LTS) |

## Direct Download Examples

```bash
# Ubuntu 24.04 LTS (Noble) - KVM optimized (recommended)
curl -O https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-disk-kvm.img

# Ubuntu 22.04 LTS (Jammy) - KVM optimized (recommended)
curl -O https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img

# Ubuntu 20.04 LTS (Focal) - KVM optimized (recommended)
curl -O https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-disk-kvm.img

# Standard images (not KVM optimized)
curl -O https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
curl -O https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
```

## Finding Available Images

You can browse available images at:
- **Main directory**: https://cloud-images.ubuntu.com/
- **Releases by version**: https://cloud-images.ubuntu.com/releases/
- **Releases by codename**: https://cloud-images.ubuntu.com/ (root shows codenames)

## Notes

- Ubuntu uses **codename-based URLs** (jammy, focal, etc.) rather than version numbers in the main path
- The `/current/` directory always points to the latest image for that release
- LTS (Long Term Support) versions are recommended for production use
- **For KVM/libvirt, use the `-disk-kvm.img` images** - they're optimized for KVM and include the KVM kernel
- Images use `.img` extension but are actually QCOW2 format files
- Standard images work fine, but KVM-optimized images have better performance

## Quick Reference

**Fedora:**
- URL: `https://download.fedoraproject.org/pub/fedora/linux/releases/{version}/Cloud/x86_64/images/`
- Example: `https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/`
- Filename pattern: `Fedora-Cloud-Base-{version}-*.qcow2`

**Debian:**
- URL: `https://cloud.debian.org/images/cloud/{codename}/latest/`
- Example: `https://cloud.debian.org/images/cloud/bookworm/latest/`
- Filename pattern: `debian-{version}-generic-amd64-*.qcow2`

**Ubuntu:**
- URL: `https://cloud-images.ubuntu.com/{codename}/current/`
- Example: `https://cloud-images.ubuntu.com/jammy/current/`
- Filename pattern: `{codename}-server-cloudimg-amd64-disk-kvm.img` (recommended for KVM)

