# Customized Hearing Aid  Mobile App

This project is a mobile application developed with Flutter and Dart to control and calibrate a custom Audio Enhancement Unit (AEU). It functions as a complete fitting interface, allowing users to perform hearing tests and generating personalized audio processing profiles using the Wide Dynamic Range Compression (WDRC) algorithm.

> ** Note:** This application is designed and optimized specifically for **Android** devices.

## Features

### WDRC Algorithm Implementation
The application includes a full implementation of the WDRC fitting engine directly in Dart. It dynamically calculates:
- Compression Ratios (CR) and Threshold Kneepoints (TK) for 10 distinct frequency bands.
- Gain Look-Up Tables (LUT) tailored to the user's specific hearing loss.
- Attack and Release times derived from HL/UCL data.

### Bluetooth Low Energy (BLE) Integration
The app ensures high-speed and reliable communication with the hardware (ESP32) using:
- MTU negotiation for optimized throughput.
- Packet fragmentation to handle large LUT data transfers.
- Custom flow control to ensure data integrity during transmission.

### In-App Audiometry
- Conducts pure-tone hearing tests from 250Hz to 8kHz.
- Measures Hearing Level (HL) and Uncomfortable Level (UCL).
- Visualizes results on an interactive audiogram chart.

## Project Structure & Key Files

Since this project relies heavily on hardware permissions, the following files are critical for configuration:

- **Application Logic (Dart):**
  `lib/main.dart`
  *(Contains the entire WDRC algorithm, UI implementation, and BLE state management.)*

- **Dependencies (YAML):**
  `pubspec.yaml`
  *(Manages packages such as `flutter_blue_plus`, `flutter_sound`, and `permission_handler`.)*

- **Android Permissions (XML):**
  `android/app/src/main/AndroidManifest.xml`
  *(Configured for Bluetooth Connect/Scan, Fine Location, and Audio Recording permissions required for Android 12+.)*

## Technical Stack

- **Framework:** Flutter
- **Language:** Dart
- **IDE:** Android Studio
- **Platform:** Android
- **Connectivity:** Bluetooth Low Energy (flutter_blue_plus)
- **Audio:** PCM16 Tone Synthesis (flutter_sound)

## Contributors

- İbrahim Umut Doruk
- Murat Can Mutlu
- Emirhan Garip

## App Screenshots
<p align="center">
  <img src="https://github.com/user-attachments/assets/e2c75d09-eaa8-4648-beda-ab966a32196d" alt="Mobile_App" width="850">
</p>




