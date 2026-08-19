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

extension Fixtures {
    /// One page of a library response. Values are invented.
    static let libraryPage = Data("""
    {
      "items": [
        {
          "asin": "B0TEST0001",
          "title": "The Long Walk Home",
          "subtitle": "A Novel",
          "authors": [{"name": "Ada Marsh"}],
          "narrators": [{"name": "Colin Reeve"}, {"name": "Jean Okoro"}],
          "series_primary": {"asin": "B0SERIES1", "title": "Wayfarer", "sequence": "2"},
          "publisher_name": "Harbour Audio",
          "runtime_length_min": 611,
          "release_date": "2024-03-12",
          "purchase_date": "2025-11-02T09:14:23.000Z",
          "product_images": {
            "500": "https://example.invalid/cover500.jpg",
            "1215": "https://example.invalid/cover1215.jpg"
          },
          "is_finished": true
        },
        {
          "asin": "B0TEST0002",
          "title": "Sparse Record",
          "purchase_date": "2025-11-03T09:14:23.000Z"
        }
      ]
    }
    """.utf8)

    static let emptyLibraryPage = Data(#"{"items": []}"#.utf8)

    static let refreshedToken = Data("""
    {"access_token": "Atna|refreshed", "expires_in": 3600, "token_type": "bearer"}
    """.utf8)
}
