//
//  OutputDeliveryService.swift
//  Vitals - Screenshot module
//
//  Vitals 简化版 OutputDeliveryService。Mio 原版需要 FileOutputService,
//  Vitals 不落盘,所以这里只保留 clipboard 分支,签名与 Mio 接口一致。
//

import AppKit
import Foundation

actor OutputDeliveryService {
    private let clipboardOutput: ClipboardOutputService

    init(clipboardOutput: ClipboardOutputService) {
        self.clipboardOutput = clipboardOutput
    }

    func deliver(_ request: DeliveryRequest) async -> DeliveryOutcome {
        // 编码 PNG + TIFF
        let bitmap = NSBitmapImageRep(cgImage: request.image.cgImage)
        bitmap.size = request.image.size
        let png = bitmap.representation(using: .png, properties: [:])
        let tiff = bitmap.representation(using: .tiff, properties: [:])

        let clipboard = await clipboardOutput.copy(png: png, tiff: tiff)
        let file: FileDeliveryOutcome = .notRequested

        return DeliveryOutcome.derive(
            policy: request.policy,
            file: file,
            clipboard: clipboard
        )
    }

    func retryPendingSinks(
        originalRequest: DeliveryRequest,
        after previous: DeliveryOutcome
    ) async -> DeliveryOutcome {
        return previous
    }
}