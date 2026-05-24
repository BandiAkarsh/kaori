/* === Edge OS — Calamares Slideshow ===
 *
 * SPDX-FileCopyrightText: 2025 Edge OS Contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * QML slideshow displayed during Edge OS installation.
 * Uses Calamares slideshow API v2.
 */

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    function nextSlide() {
        console.log("Edge OS slideshow: next slide");
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 5000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide {
        anchors.fill: parent

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -40
            text: "Welcome to Edge OS"
            font.pixelSize: 32
            font.bold: true
            color: "#00d4aa"
            horizontalAlignment: Text.Center
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 10
            text: "A modern, performance-optimized Linux distribution<br/>" +
                  "built for developers and power users."
            font.pixelSize: 16
            color: "#e0e0e0"
            horizontalAlignment: Text.Center
            wrapMode: Text.WordWrap
            width: parent.width * 0.8
        }
    }

    Slide {
        anchors.fill: parent

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -60
            text: "Advanced Linux Kernel"
            font.pixelSize: 28
            font.bold: true
            color: "#00d4aa"
            horizontalAlignment: Text.Center
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 0
            text: "• LLVM ThinLTO for faster compilation & smaller kernel<br/>" +
                  "• sched_ext (BPF schedulers) for dynamic workload tuning<br/>" +
                  "• MGLRU for responsive memory management<br/>" +
                  "• DAMON proactive reclaim for memory pressure<br/>" +
                  "• BBR3 congestion control for optimal networking<br/>" +
                  "• zram compressed swapping for better RAM usage"
            font.pixelSize: 14
            color: "#c0c0c0"
            horizontalAlignment: Text.Left
            wrapMode: Text.WordWrap
            width: parent.width * 0.75
        }
    }

    Slide {
        anchors.fill: parent

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -60
            text: "Hyprland Desktop"
            font.pixelSize: 28
            font.bold: true
            color: "#00d4aa"
            horizontalAlignment: Text.Center
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 0
            text: "• Dynamic tiling Wayland compositor<br/>" +
                  "• Beautiful, customizable desktop environment<br/>" +
                  "• Waybar status bar + Rofi app launcher<br/>" +
                  "• SwayNC notification center<br/>" +
                  "• Wallust color generation from wallpaper<br/>" +
                  "• Smooth animations & visual effects"
            font.pixelSize: 14
            color: "#c0c0c0"
            horizontalAlignment: Text.Left
            wrapMode: Text.WordWrap
            width: parent.width * 0.75
        }
    }

    Slide {
        anchors.fill: parent

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -40
            text: "Built with Rust"
            font.pixelSize: 28
            font.bold: true
            color: "#00d4aa"
            horizontalAlignment: Text.Center
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 10
            text: "Core utilities rebuilt in Rust (uutils) for<br/>" +
                  "memory safety, reliability, and performance.<br/><br/>" +
                  "80+ everyday commands — cp, ls, mv, rm, cat,<br/>" +
                  "date, sort, grep, and many more — all in Rust."
            font.pixelSize: 16
            color: "#e0e0e0"
            horizontalAlignment: Text.Center
            wrapMode: Text.WordWrap
            width: parent.width * 0.8
        }
    }

    Slide {
        anchors.fill: parent

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -40
            text: "Thank You for Choosing Edge OS"
            font.pixelSize: 28
            font.bold: true
            color: "#00d4aa"
            horizontalAlignment: Text.Center
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 10
            text: "Installation in progress...<br/><br/>" +
                  "This may take a few minutes depending on your system.<br/>" +
                  "Your new system will be ready soon."
            font.pixelSize: 16
            color: "#e0e0e0"
            horizontalAlignment: Text.Center
            wrapMode: Text.WordWrap
            width: parent.width * 0.8
        }
    }

    function onActivate() {
        console.log("Edge OS slideshow activated");
        presentation.currentSlide = 0;
    }

    function onLeave() {
        console.log("Edge OS slideshow deactivated");
    }
}
