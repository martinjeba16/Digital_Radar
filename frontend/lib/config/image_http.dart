/// Shared HTTP headers for loading images from Wikimedia / Commons / OSM.
///
/// Wikimedia rejects the default Dart/Flutter User-Agent (403 or HTML).
/// Every [CachedNetworkImage] and raw image download MUST use these headers
/// or images will silently fail in Recents / Bookmarks / Detail while
/// notifications (which already set a User-Agent) still work.
class ImageHttp {
  static const userAgent =
      'DigitalRadarApp/1.0 (https://github.com/digital-radar; contact@example.com)';

  static const Map<String, String> headers = {
    'User-Agent': userAgent,
    'Accept': 'image/jpeg,image/png,image/webp,image/*,*/*;q=0.8',
  };
}
