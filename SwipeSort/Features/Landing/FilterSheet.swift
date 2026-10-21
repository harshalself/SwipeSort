import SwiftUI

/// A sheet for editing a `SwipeFilter` in-place.
///
/// Writes directly to the bound `SwipeFilter` value so the parent view's
/// `.task(id: filter)` fires a reload immediately on any change.
struct FilterSheet: View {
    @Binding var filter: SwipeFilter
    var onFilterChange: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Media Type") {
                    Menu {
                        ForEach(SwipeFilter.MediaTypeOption.allCases, id: \.self) { option in
                            Button {
                                if filter.selectedMediaTypes.contains(option) {
                                    filter.selectedMediaTypes.remove(option)
                                } else {
                                    filter.selectedMediaTypes.insert(option)
                                }
                            } label: {
                                if filter.selectedMediaTypes.contains(option) {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(filter.selectedMediaTypes.isEmpty ? "Select Media Types" : filter.selectedMediaTypes.map(\.rawValue).sorted().joined(separator: ", "))
                                .foregroundStyle(filter.selectedMediaTypes.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Sort") {
                    Picker("Order", selection: $filter.sortOrder) {
                        Text("Newest first").tag(SwipeFilter.SortOrder.newestFirst)
                        Text("Oldest first").tag(SwipeFilter.SortOrder.oldestFirst)
                    }
                }

                Section("Date range") {
                    DateRangePicker(range: $filter.dateRange)
                }
            }
            .onChange(of: filter) { _, _ in
                onFilterChange?()
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") { filter = .unfiltered }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct DateRangePicker: View {
    @Binding var range: ClosedRange<Date>?

    @State private var enabled: Bool
    @State private var start: Date
    @State private var end: Date

    // Hydrate local state from the incoming binding so reopening the sheet after
    // a range was already set shows the previously chosen values rather than
    // always resetting to the last-year default.
    init(range: Binding<ClosedRange<Date>?>) {
        self._range = range
        let existing = range.wrappedValue
        let defaultStart = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        _enabled = State(initialValue: existing != nil)
        _start = State(initialValue: existing?.lowerBound ?? defaultStart)
        _end = State(initialValue: existing?.upperBound ?? Date())
    }

    // Computed bindings propagate picks to the outer range immediately,
    // avoiding three separate `.onChange` observers that could race.
    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: { start = $0; syncRange() })
    }
    private var endBinding: Binding<Date> {
        Binding(get: { end }, set: { end = $0; syncRange() })
    }
    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { enabled = $0; syncRange() })
    }

    private func syncRange() {
        // Clamp inverted picks (end < start) so the NSPredicate always yields
        // valid results; silently swapping prevents a confusing empty-state.
        let low = min(start, end)
        let high = max(start, end)
        range = enabled ? (low...high) : nil
    }

    var body: some View {
        Toggle("Enable", isOn: enabledBinding)
        if enabled {
            DatePicker("From", selection: startBinding, displayedComponents: .date)
            DatePicker("To", selection: endBinding, displayedComponents: .date)
        }
    }
}
