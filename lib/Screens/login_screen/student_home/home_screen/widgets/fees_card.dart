// ignore_for_file: prefer_typing_uninitialized_variables

import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';

class FeesCard extends StatelessWidget {
  final height,
      width,
      neumorphicStyle,
      feeData,
      buttonTrailing,
      subtitle,
      title,
      isDark;
  const FeesCard({
    Key? key,
    this.height,
    this.width,
    this.neumorphicStyle,
    this.feeData,
    this.buttonTrailing,
    this.subtitle,
    this.title,
    this.isDark,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: NeumorphicButton(
        padding: EdgeInsets.only(
          top: height * 0.015,
          bottom: height * 0.015,
          left: width * 0.025,
          right: width * 0.01,
        ),
        onPressed: () {}, //TODO receipt download maybe?
        style: neumorphicStyle,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            iconColor: const Color(0xffba3237),
            collapsedIconColor: isDark ? Colors.white : Colors.black,
            title: Text(
              feeData.amountPaid,
              style: buttonTrailing.copyWith(
                fontSize: (width * 0.06).clamp(18.0, 24.0),
              ),
            ),
            subtitle: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: width * 0.02,
                vertical: height * 0.01,
              ),
              child: Text(
                "For Year ${feeData.yearNumber} on ${feeData.date}",
                style: subtitle,
              ),
            ),
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: width * 0.04,
                  vertical: height * 0.02,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Challan No:", style: title),
                    Expanded(
                      child: Text(
                        feeData.challanNumber,
                        style: subtitle,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ), //ChallanNo
              ),
              (feeData.mode != "CASH")
                  ? Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: width * 0.04,
                        vertical: height * 0.02,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Cheque No:", style: title),
                          Expanded(
                            child: Text(
                              feeData.chequeNumber,
                              style: subtitle,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Container(),
            ],
          ),
        ),
      ),
    );
  }
}
