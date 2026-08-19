import Foundation

/// Recorded response shapes with every real value replaced. No fixture in this
/// repository contains a real token, key, or customer identifier.
enum Fixtures {
    static let registrationSuccess = Data("""
    {
      "response": {
        "success": {
          "tokens": {
            "mac_dms": {
              "adp_token": "{enc:sample-adp-token}",
              "device_private_key": "-----BEGIN RSA PRIVATE KEY-----\\nMIIsample\\n-----END RSA PRIVATE KEY-----\\n"
            },
            "bearer": {
              "access_token": "Atna|sample-access",
              "refresh_token": "Atnr|sample-refresh",
              "expires_in": "3600"
            }
          },
          "extensions": {
            "customer_info": {
              "user_id": "amzn1.account.SAMPLE",
              "name": "Sample Listener"
            }
          }
        }
      }
    }
    """.utf8)

    static let registrationMissingKey = Data("""
    {
      "response": {
        "success": {
          "tokens": {
            "mac_dms": { "adp_token": "{enc:sample-adp-token}" },
            "bearer": {
              "access_token": "Atna|sample-access",
              "refresh_token": "Atnr|sample-refresh",
              "expires_in": "3600"
            }
          }
        }
      }
    }
    """.utf8)

    static let registrationFailure = Data("""
    {
      "response": {
        "error": {
          "code": "InvalidValue",
          "message": "Invalid authorization code"
        }
      }
    }
    """.utf8)
}
