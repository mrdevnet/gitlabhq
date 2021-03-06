/* eslint-disable func-names, space-before-function-paren, consistent-return, no-var, no-undef, no-else-return, prefer-arrow-callback, padded-blocks, max-len */
// Render Gitlab flavoured Markdown
//
// Delegates to syntax highlight and render math
//
(function() {
  $.fn.renderGFM = function() {
    this.find('.js-syntax-highlight').syntaxHighlight();
    this.find('.js-render-math').renderMath();
  };

  $(document).on('ready page:load', function() {
    return $('body').renderGFM();
  });

}).call(this);
