import Foundation

/// What the account's Audible membership is.
///
/// The API does not report how many credits are left. It reports the plan, its
/// state, and what is billed next, so that is what this carries.
public struct Membership: Sendable, Hashable, Codable {
    /// Plan name, such as "Audible Premium Plus".
    public let name: String
    /// "Active", or whatever else the server says.
    public let status: String
    /// Tier the plan belongs to, such as "Gold".
    public let tier: String?
    public let nextBillDate: Date?
    public let nextBillAmount: Decimal?
    public let currencyCode: String?

    public var isActive: Bool { status.caseInsensitiveCompare("Active") == .orderedSame }

    /// The next charge as text, when both parts are known.
    public var nextBillText: String? {
        guard let nextBillAmount, let currencyCode else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return formatter.string(from: nextBillAmount as NSDecimalNumber)
    }
}

/// Reads the account's membership.
public struct MembershipService: Sendable {
    private let client: AudibleClient

    /// Everything the membership call is willing to return.
    static let responseGroups = [
        "migration_details",
        "subscription_details_rodizio",
        "subscription_details_premium",
        "customer_segment",
        "subscription_details_channels"
    ].joined(separator: ",")

    public init(client: AudibleClient) {
        self.client = client
    }

    /// The membership, or nil when the account has none.
    public func membership() async throws -> Membership? {
        let data = try await client.send(
            method: "GET",
            path: "customer/information",
            query: ["response_groups": MembershipService.responseGroups],
            body: nil)
        return MembershipService.parse(data)
    }

    static func parse(_ data: Data) -> Membership? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = root["customer_details"] as? [String: Any],
              let subscription = details["subscription"] as? [String: Any],
              let plans = subscription["subscription_details"] as? [[String: Any]]
        else { return nil }

        // An account can hold more than one plan. The active one is the one
        // worth showing.
        let plan = plans.first { ($0["status"] as? String) == "Active" } ?? plans.first
        guard let plan, let name = plan["name"] as? String else { return nil }

        let bill = plan["next_bill_amount"] as? [String: Any]
        let amount = (bill?["currency_value"] as? NSNumber).map { Decimal($0.doubleValue) }

        return Membership(
            name: name,
            status: plan["status"] as? String ?? "Unknown",
            tier: plan["group_type"] as? String,
            nextBillDate: (plan["next_bill_date"] as? String).flatMap {
                ISO8601DateFormatter.withFraction.date(from: $0)
                    ?? ISO8601DateFormatter.withoutFraction.date(from: $0)
            },
            nextBillAmount: amount,
            currencyCode: bill?["currency_code"] as? String)
    }
}
