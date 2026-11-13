/// A Korean publisher or the word 'nationwide' does not establish geography.
/// Fail closed for overseas and ambiguous search results, including cached ones.
abstract final class DomesticNews {
  static final _korea = RegExp(
    r'대한민국|한국|서울|부산|인천|대구|광주|대전|울산|세종|경기|강원|충청|전라|경상|제주|코레일|KORAIL|서울교통공사|공항철도',
    caseSensitive: false,
  );
  static final _overseas = RegExp(
    r'스페인|에스파냐|마드리드|바르셀로나|프랑스|파리|영국|런던|독일|베를린|이탈리아|포르투갈|미국|뉴욕|일본|도쿄|중국|베이징|해외|외국|Spain|Spanish|Madrid|Barcelona|France|French|London|Germany|Italy|Portugal',
    caseSensitive: false,
  );
  static bool accepts(String text) =>
      _korea.hasMatch(text) && !_overseas.hasMatch(text);
}
