import Foundation

/// Throwaway RSA keys used only by the test suite. They were generated for
/// this repository and protect nothing.
enum TestKeys {
    /// The same key in PKCS#1 form, as `BEGIN RSA PRIVATE KEY`.
    static let rsa2048PKCS1 = [
        "-----BEGIN RSA PRIVATE KEY-----",
        "MIIEpAIBAAKCAQEA1wO008GMTvjZsfH9lNnxkmp3ZWctFyBFF9QYLLuu2ZzbcoT7",
        "UFnjraLmoZV5cj+QFp8F8wxGPs+N3Ilfd17RJfaO0Yl1Cry4XZvAqoFIjC9CGv+1",
        "UkY6L1a+mPyIHvZz2F/paQvFo7FebObqOykDbZVdbNgjtjGcVDNtKRY8gwwKn4op",
        "47+J4ZV+uJ/Iv/i+hqJEVrNCCJvh2m6S1W5/IbXTZmL+JMAxKTKg4vROLDPYtRM/",
        "5PG8qpTBMY0zCwkEh4qxwTFQOTyHgP6Bb5I0odLYNTX0P/NQUtOvmQkbkDKAqowr",
        "B02zNrmsea+auSkTk4RIj6rrIsRW1DUvl6/EAQIDAQABAoIBAGJmvtX+iSEHQFHw",
        "xrXdvHHeqb/NpVQlH5nVJi8qwc2zvLa/Z2iRiuJHYDdo+giwUFgZ9RYTcv6B7JGW",
        "iQtPaHZwTVJWDyuXzOSCSH1/51zIr/89MZVysGRD1bycLgvFjKTk2CSMD6pnnShH",
        "0cC7d2cqaXRLwqQ6NipO0tFv7Men32GNkAmfCCCpN/4Lqdx86QcYsjB/WpPdH62m",
        "WXZQG6Srvn5hOBxmIaI77J6QqV/BarnjC6r45+KsUezBLEEaub1zv0Rzb6v1AwBd",
        "UiVETddWuNa4ipQfeeBeUskiq+o9dbE6qydoAmIf6EqU2VwQ5d1PcC53QEih4DtC",
        "WDhxvaUCgYEA63u0ZDVu2kZ/lyA1n/80ZNnfNGHUgHCKwdA9xezNgq83nRSVjF1r",
        "aFGwN855GH80wX7bnzGjtSFnGUHWpkHV/igzRGQQygPZbBQ5Hh3ngflB5rQDZUYZ",
        "gJ683wOW91AiSQl2DfWFPbygT7EkbySAtEJy69Op27lknzp2yXYzYM8CgYEA6b91",
        "yZR6aKVO1GfcM1GE/yhdRrEhEQfJztHQh4/kCA6ii7BVbNB4b7Ies7nMsmp9sOeg",
        "P79cPfGQSP0hOW+lmIwAsZFf0jiFta479wJeqg7Stw89N3DIFV7AUQT5Ggrx3/LR",
        "TGoN0Zj6NqbjPPwldUa6nRDiXosp9E+pJoKioi8CgYEAj5eoYW6/wPQ6O1JVwNGj",
        "BlhgphV9ujBmPFcaRAXpL2Ze+DckFiqlI0CkvvL1nr160v7jN0jStdG/h4RBOrJs",
        "pgWndW27WyRLwX73cWj00anHyME+TNQZGvgw3aDXvskrjvPo/AwaCpJqAw5W1Dsj",
        "DEh0wV8ZdbWwKPRCmQitvbsCgYEAoihxtVNtDBXKNy6KI4vlIQJGm1kcYG0vwmvq",
        "J3FaN4C3oQLGcIO7WXmPNQ2rhQa9hbFaiX7ephZkC06X8vmSPt65SHZarEML93sV",
        "HIonVACOi/JlfIWgOLsP3eT+TuPS4pLYQhO83HAs/ScPs+oUrmRP59CjygTvKQ7u",
        "gMnVu38CgYAI10dWOKaN7mBT/P1ev5q7LX4Jtz8ApCpVKwjJJN3zFtH0AOSaMsx0",
        "3+F4mGJa5NiwrQ8hCx5iGpRb6MRLN1t9iMTmZHFeSoyT66m+NTaSINFc2EjdIPYx",
        "qx5HXXgMGLDGKwTQALfyj0lH2bp9VjYy8Ol+cABdA/2YMLFu4lH26w==",
        "-----END RSA PRIVATE KEY-----",
    ].joined(separator: "\n")

    /// The same key in PKCS#8 form, as `BEGIN PRIVATE KEY`.
    static let rsa2048PKCS8 = [
        "-----BEGIN PRIVATE KEY-----",
        "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDXA7TTwYxO+Nmx",
        "8f2U2fGSandlZy0XIEUX1Bgsu67ZnNtyhPtQWeOtouahlXlyP5AWnwXzDEY+z43c",
        "iV93XtEl9o7RiXUKvLhdm8CqgUiML0Ia/7VSRjovVr6Y/Ige9nPYX+lpC8WjsV5s",
        "5uo7KQNtlV1s2CO2MZxUM20pFjyDDAqfiinjv4nhlX64n8i/+L6GokRWs0IIm+Ha",
        "bpLVbn8htdNmYv4kwDEpMqDi9E4sM9i1Ez/k8byqlMExjTMLCQSHirHBMVA5PIeA",
        "/oFvkjSh0tg1NfQ/81BS06+ZCRuQMoCqjCsHTbM2uax5r5q5KROThEiPqusixFbU",
        "NS+Xr8QBAgMBAAECggEAYma+1f6JIQdAUfDGtd28cd6pv82lVCUfmdUmLyrBzbO8",
        "tr9naJGK4kdgN2j6CLBQWBn1FhNy/oHskZaJC09odnBNUlYPK5fM5IJIfX/nXMiv",
        "/z0xlXKwZEPVvJwuC8WMpOTYJIwPqmedKEfRwLt3ZyppdEvCpDo2Kk7S0W/sx6ff",
        "YY2QCZ8IIKk3/gup3HzpBxiyMH9ak90fraZZdlAbpKu+fmE4HGYhojvsnpCpX8Fq",
        "ueMLqvjn4qxR7MEsQRq5vXO/RHNvq/UDAF1SJURN11a41riKlB954F5SySKr6j11",
        "sTqrJ2gCYh/oSpTZXBDl3U9wLndASKHgO0JYOHG9pQKBgQDre7RkNW7aRn+XIDWf",
        "/zRk2d80YdSAcIrB0D3F7M2CrzedFJWMXWtoUbA3znkYfzTBftufMaO1IWcZQdam",
        "QdX+KDNEZBDKA9lsFDkeHeeB+UHmtANlRhmAnrzfA5b3UCJJCXYN9YU9vKBPsSRv",
        "JIC0QnLr06nbuWSfOnbJdjNgzwKBgQDpv3XJlHpopU7UZ9wzUYT/KF1GsSERB8nO",
        "0dCHj+QIDqKLsFVs0Hhvsh6zucyyan2w56A/v1w98ZBI/SE5b6WYjACxkV/SOIW1",
        "rjv3Al6qDtK3Dz03cMgVXsBRBPkaCvHf8tFMag3RmPo2puM8/CV1RrqdEOJeiyn0",
        "T6kmgqKiLwKBgQCPl6hhbr/A9Do7UlXA0aMGWGCmFX26MGY8VxpEBekvZl74NyQW",
        "KqUjQKS+8vWevXrS/uM3SNK10b+HhEE6smymBad1bbtbJEvBfvdxaPTRqcfIwT5M",
        "1Bka+DDdoNe+ySuO8+j8DBoKkmoDDlbUOyMMSHTBXxl1tbAo9EKZCK29uwKBgQCi",
        "KHG1U20MFco3Looji+UhAkabWRxgbS/Ca+oncVo3gLehAsZwg7tZeY81DauFBr2F",
        "sVqJft6mFmQLTpfy+ZI+3rlIdlqsQwv3exUciidUAI6L8mV8haA4uw/d5P5O49Li",
        "kthCE7zccCz9Jw+z6hSuZE/n0KPKBO8pDu6AydW7fwKBgAjXR1Y4po3uYFP8/V6/",
        "mrstfgm3PwCkKlUrCMkk3fMW0fQA5JoyzHTf4XiYYlrk2LCtDyELHmIalFvoxEs3",
        "W32IxOZkcV5KjJPrqb41NpIg0VzYSN0g9jGrHkddeAwYsMYrBNAAt/KPSUfZun1W",
        "NjLw6X5wAF0D/ZgwsW7iUfbr",
        "-----END PRIVATE KEY-----",
    ].joined(separator: "\n")
}
