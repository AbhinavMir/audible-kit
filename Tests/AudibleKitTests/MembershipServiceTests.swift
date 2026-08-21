import Foundation
import Testing
@testable import AudibleKit

@Suite("Membership")
struct MembershipServiceTests {

    static let response = Data("""
    {
      "customer_details": {
        "subscription": {
          "subscription_details": [
            {
              "name": "Audible Premium Plus",
              "status": "Active",
              "group_type": "Gold",
              "next_bill_date": "2026-09-15T19:18:01.000Z",
              "next_bill_amount": {"currency_code": "USD", "currency_value": 14.95}
            }
          ]
        }
      }
    }
    """.utf8)

    @Test("The plan comes back with its name, tier, and next charge")
    func parsesMembership() throws {
        let membership = try #require(MembershipService.parse(Self.response))
        #expect(membership.name == "Audible Premium Plus")
        #expect(membership.tier == "Gold")
        #expect(membership.isActive)
        #expect(membership.nextBillDate != nil)
        #expect(membership.nextBillText == "$14.95")
    }

    @Test("An active plan is preferred over a cancelled one")
    func picksTheActivePlan() throws {
        let response = Data("""
        {"customer_details": {"subscription": {"subscription_details": [
          {"name": "Old Plan", "status": "Cancelled"},
          {"name": "Audible Plus", "status": "Active"}
        ]}}}
        """.utf8)
        #expect(MembershipService.parse(response)?.name == "Audible Plus")
    }

    @Test("An account with no membership yields nothing, not an empty plan")
    func noMembership() {
        #expect(MembershipService.parse(Data(#"{"customer_details":{}}"#.utf8)) == nil)
    }

    @Test("A plan with no billing figures still reads")
    func handlesMissingBilling() throws {
        let response = Data("""
        {"customer_details": {"subscription": {"subscription_details": [
          {"name": "Audible Plus", "status": "Active"}
        ]}}}
        """.utf8)
        let membership = try #require(MembershipService.parse(response))
        #expect(membership.nextBillText == nil)
        #expect(membership.nextBillDate == nil)
    }
}
