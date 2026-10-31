# OmenForge 🛡️🔥

**OmenForge** is a native FreeBSD utility and daemon engineered to manage thermal performance, fan speeds, and ACPI power profiles on HP OMEN series laptops.

In Windows, HP OMEN systems rely on *HP Omen Gaming Hub* to manipulate embedded controller (EC) registers. **OmenForge** fills this gap on FreeBSD, interacting directly with ACPI hardware interfaces and `sysctl` nodes to give you full control over system thermals and cooling profiles.

---

## ✨ Features

* **Custom Thermal Profiles:** Switch between `Quiet`, `Balanced`, and `Performance/Max` modes.
* **EC & Fan Speed Control:** Direct reading and modification of ACPI fan speed registers.
* **Thermal Monitoring:** Real-time tracking of CPU, GPU, and ambient system temperatures.
* **Daemon & CLI Modes:** Runs as a background service (`omenforged`) or interactive CLI control tool (`omenforge-ctl`).
* **FreeBSD Native:** Built specifically for FreeBSD using native FreeBSD APIs and hardware interfaces (no Linux compatibility layers required).

---

## 📋 Requirements

* **OS:** FreeBSD 14.0+ / 15.0+
* **Privileges:** Root access (required for modifying ACPI/EC sysctls and dev nodes)
* **Kernel Modules:**
  * `acpi_hp.ko` (or custom ACPI interface)
  * `coretemp.ko` / `amdtemp.ko`

---

## 🚀 Installation & Usage

### Building from Source

```bash
git clone [https://github.com/aleksander-haugas/OmenForge.git](https://github.com/aleksander-haugas/OmenForge.git)
cd OmenForge
make
sudo make install
