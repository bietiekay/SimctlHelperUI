//
//  CloneDeviceView.swift
//  SimctlHelperUI
//
//  Created by Daniel Kirstenpfad on 09.02.26.
//

import SwiftUI

struct CloneDeviceView: View {
    @Binding var isPresented: Bool
    let deviceName: String
    let onClone: (String) async throws -> Void
    
    @State private var newName: String = ""
    @State private var isCloning: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.t("Clone Device"))
                .font(.headline)
            
            Text(L10n.f("Clone \"%@\"", deviceName))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            TextField(L10n.t("New device name"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if isValid {
                        cloneDevice()
                    }
                }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button(L10n.t("Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button(L10n.t("Clone")) {
                    cloneDevice()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCloning)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            newName = L10n.f("%@ Copy", deviceName)
        }
    }
    
    private var isValid: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private func cloneDevice() {
        guard isValid else { return }
        
        isCloning = true
        errorMessage = nil
        
        Task {
            do {
                try await onClone(newName.trimmingCharacters(in: .whitespaces))
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isCloning = false
        }
    }
}
