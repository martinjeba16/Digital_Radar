enum LanguagePreference { en, ta }

extension LanguagePreferenceLabel on LanguagePreference {
  String get label => switch (this) {
        LanguagePreference.en => 'EN',
        LanguagePreference.ta => 'TA',
      };

  LanguagePreference get toggle =>
      this == LanguagePreference.en ? LanguagePreference.ta : LanguagePreference.en;
}
